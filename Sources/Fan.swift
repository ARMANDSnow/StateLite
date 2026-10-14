import Foundation
import Darwin

struct FanReading {
    let id: Int
    let rpm: Double?
    let minimumRPM: Double?
    let maximumRPM: Double?
    let targetRPM: Double?
    /// Raw mode: 0 firmware auto, 1 manual, 3 macOS thermal manager on M3/M4.
    let hardwareMode: Int?
}
struct FanSnapshot {
    let fans: [FanReading]
    let detail: String
}

/// Call from the existing serial sampler queue. No writes or helper requests.
final class FanSampler {
    private var connection: OpaquePointer?
    private var retryAfter = Date.distantPast
    deinit { if let connection { SLFanClose(connection) } }
    func reset() {
        if let connection { SLFanClose(connection) }
        connection = nil
        retryAfter = .distantPast
    }
    func sample() -> FanSnapshot {
        if connection == nil && Date() >= retryAfter {
            connection = SLFanOpen()
            retryAfter = Date().addingTimeInterval(60)
        }
        guard connection != nil, let count = read("FNum"), count.rounded() == count,
              count >= 0, count <= 10 else {
            if let connection {
                SLFanClose(connection)
                self.connection = nil
                retryAfter = Date().addingTimeInterval(60)
            }
            return FanSnapshot(fans: [], detail: "无法读取风扇；60 秒后重试。AppleSMC 非公开只读接口。")
        }
        let fans = (0..<Int(count)).map { id -> FanReading in
            func rpm(_ suffix: String) -> Double? {
                guard let value = read("F\(id)\(suffix)"), value <= 20000 else { return nil }
                return value
            }
            let rawMode = read("F\(id)md") ?? read("F\(id)Md")
            return FanReading(id: id, rpm: rpm("Ac"), minimumRPM: rpm("Mn"),
                              maximumRPM: rpm("Mx"), targetRPM: rpm("Tg"),
                              hardwareMode: rawMode.flatMap { $0.rounded() == $0 && $0 >= 0 && $0 <= 255 ? Int($0) : nil })
        }
        return FanSnapshot(fans: fans, detail: fans.isEmpty ? "未检测到风扇" : "AppleSMC 只读实测；0 RPM 表示停转，— 表示不可读。")
    }
    private func read(_ key: String) -> Double? {
        var value = 0.0
        return key.withCString { SLFanRead(connection, $0, &value) } ? value : nil
    }
}

enum FanMode: String { case system, boost }
struct FanControlError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One authenticated helper session persists while the app renews its 10-second lease.
final class FanController {
    typealias Completion = (Result<Void, FanControlError>) -> Void
    private let lock=NSLock()
    private let worker=DispatchQueue(label:"StateLite.fan.authorization")
    private var fd:Int32 = -1
    private var generation=0
    private var starting=false
    private var closed=false
    private var confirmedTargets:[Int:Double]?
    private var nextRequest:UInt32=0
    private var pendingID:UInt32=0
    private var pendingTargets:[Int:Double]?
    private var pendingCommand=""
    private var pending:Completion?
    private var timer:DispatchSourceTimer?
    private var timeout:DispatchWorkItem?
    var onStateChange:((Bool,String)->Void)?
    private var helperPath:String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/FanHelper").path }
    var isAvailable:Bool { FileManager.default.isExecutableFile(atPath:helperPath) }
    var installationState:Int32 { helperPath.withCString { SLFanHelperInstallationState($0) } }
    var installationDescription:String {
        switch installationState {
        case 0: return "已安装 · 本版本调速无需再次授权"
        case 1: return "未安装 · 首次应用时授权安装"
        case 2: return "需要授权更新助手或应用身份"
        default: return "安装状态无法验证，请检查诊断"
        }
    }
    var boostActive:Bool { targetsRPM != nil }
    var targetsRPM:[Int:Double]? {lock.lock();defer{lock.unlock()};return confirmedTargets}
    var unavailableReason:String {"缺少 StateLite 自有风扇助手，请重新安装。"}

    /// Supply every fan ID exactly once; helper independently validates hardware min/max.
    func setTargets(_ targets:[Int:Double],completion:@escaping Completion) {
        guard !targets.isEmpty,targets.count<=10,targets.allSatisfy({(0...9).contains($0.key) && $0.value.isFinite && $0.value>=0 && $0.value<=16000}) else {
            finish(completion,.failure(.init(message:"目标转速格式无效")));return
        }
        request(targets,completion:completion)
    }
    func setMode(_ mode:FanMode,completion:@escaping Completion) {
        if mode == .system {request(nil,completion:completion);return}
        let fans=FanSampler().sample().fans
        var targets:[Int:Double]=[:]
        for fan in fans {if let maximum=fan.maximumRPM{targets[fan.id]=maximum}}
        guard !fans.isEmpty && targets.count==fans.count else {finish(completion,.failure(.init(message:"无法读取全部风扇范围")));return}
        setTargets(targets,completion:completion)
    }
    func restoreSystemControl(completion:@escaping Completion) {request(nil,completion:completion)}
    private func request(_ targets:[Int:Double]?,completion:@escaping Completion) {
        lock.lock()
        guard !closed else {lock.unlock();finish(completion,.failure(.init(message:"控制器已关闭")));return}
        guard pending == nil && !starting else {lock.unlock();finish(completion,.failure(.init(message:"正在应用上一项风扇设置")));return}
        if targets == nil && fd<0 {lock.unlock();finish(completion,.failure(.init(message:"当前没有 StateLite 控制会话；未向硬件发送恢复命令。")));return}
        nextRequest = nextRequest == UInt32.max ? 1 : nextRequest+1
        pendingID=nextRequest;let id=pendingID
        pending=completion;pendingTargets=targets
        if let targets {
            pendingCommand="SET \(id) "+targets.sorted(by:{$0.key<$1.key}).map{"\($0.key)=\(String(format:"%.2f",locale:Locale(identifier:"en_US_POSIX"),$0.value))"}.joined(separator:" ")+"\n"
        } else {pendingCommand="SYSTEM \(id)\n"}
        if fd>=0 {
            let token=generation;let sent=sendLocked(pendingCommand);lock.unlock()
            if sent {armTimeout(token:token,id:id)} else {fail("助手连接断开；会尝试恢复系统控制。",token:token)}
            return
        }
        starting=true;generation+=1;let token=generation;lock.unlock()
        guard isAvailable else {fail(unavailableReason,token:token);return}
        worker.async { [weak self] in
            guard let self else{return};var channel:Int32 = -1
            let status=self.helperPath.withCString{SLFanLaunchHelper($0,&channel)}
            self.lock.lock();let cancelled=self.closed || self.generation != token
            self.starting=false;if status==0 && !cancelled{self.fd=channel};self.lock.unlock()
            if status != 0 {
                let detail:String
                switch status {
                case -60006: detail="管理员授权已取消。"
                case -71002: detail="助手安装未确认："+String(cString:SLFanLastServiceError())
                case -71003: detail="已安装的调速服务未能连接，请检查系统后台项目是否允许运行。"
                case -71005: detail="助手安装后身份校验未通过。"
                default: detail="助手启动失败（状态 \(status)）；请保留此错误码。"
                }
                self.fail(detail,token:token);return
            }
            if cancelled {SLFanDisconnect(channel);return}
            self.armTimeout(token:token,id:id);self.startHeartbeat(channel,token:token);self.readMessages(channel,token:token)
        }
    }
    // Caller holds lock, preventing writes to a closed/reused descriptor.
    private func sendLocked(_ command:String)->Bool {fd>=0 && command.withCString{SLFanSendCommand(fd,$0)}>0}
    private func startHeartbeat(_ channel:Int32,token:Int) {
        let timer=DispatchSource.makeTimerSource(queue:DispatchQueue.global(qos:.utility))
        timer.schedule(deadline:.now(),repeating:2)
        timer.setEventHandler{[weak self] in
            guard let self else{return};self.lock.lock();defer{self.lock.unlock()}
            if self.fd==channel && self.generation==token{_ = self.sendLocked("PING\n")}
        }
        timer.resume();lock.lock()
        if fd==channel && generation==token{self.timer=timer}else{timer.cancel()};lock.unlock()
    }
    private func readMessages(_ channel:Int32,token:Int) {
        lock.lock();guard fd==channel && generation==token else{lock.unlock();return}
        let readFD=dup(channel);lock.unlock()
        guard readFD>=0 else{fail("无法读取助手连接",token:token);return}
        defer{SLFanDisconnect(readFD)}
        var line=""
        while true {
            lock.lock();let valid=fd==channel && generation==token;lock.unlock();if !valid{return}
            var byte:CChar=0;let result=SLFanReceive(readFD,&byte,500)
            if result<0 {fail("助手连接结束，尚未收到恢复确认；请检查实际风扇状态。",token:token);return}
            if result==0{continue}
            if byte != 10 {if line.count<1024{line.append(Character(UnicodeScalar(UInt8(bitPattern:byte))))}else{fail("助手响应过长",token:token);return};continue}
            let message=line;line=""
            if message=="READY" {
                lock.lock();guard fd==channel && generation==token else{lock.unlock();return}
                let sent=sendLocked(pendingCommand);lock.unlock()
                if !sent{fail("发送转速请求失败",token:token);return};continue
            }
            if message.hasPrefix("ERROR") {fail("调速未确认：\(message)。助手将尝试交回系统控制。",token:token);return}
            if message=="RESTORED" {fail("会话已结束，助手报告已交回系统控制。",token:token);return}
            let parts=message.split(separator:" ").map(String.init)
            guard parts.count>=3,parts[0]=="ACK",let id=UInt32(parts[1]) else{continue}
            lock.lock()
            guard fd==channel && generation==token else{lock.unlock();return}
            guard pending != nil && pendingID==id else{lock.unlock();continue}
            var received:[Int:Double]?=nil
            var acceptable=parts[2]=="SYSTEM" && pendingTargets==nil && parts.count==3
            if parts[2]=="TARGETS",let expected=pendingTargets {
                var values:[Int:Double]=[:];var wellFormed=true
                for item in parts.dropFirst(3) {
                    let pair=item.split(separator:"=")
                    guard pair.count==2,let fan=Int(pair[0]),let rpm=Double(pair[1]),rpm.isFinite,values[fan]==nil else{wellFormed=false;break}
                    values[fan]=rpm
                }
                acceptable=wellFormed && values.count==expected.count && expected.allSatisfy{abs((values[$0.key] ?? -.infinity)-$0.value)<1}
                received=values
            }
            guard acceptable else{lock.unlock();fail("助手确认的目标与当前请求不一致",token:token);return}
            confirmedTargets=received;let callback=pending;pending=nil;pendingTargets=nil;timeout?.cancel();timeout=nil;lock.unlock()
            if let callback{finish(callback,.success(()))}
            let detail=received.map{values in "已应用："+values.sorted(by:{$0.key<$1.key}).map{"风扇\($0.key+1) \(Int($0.value)) RPM"}.joined(separator:"，")+"；保持至切回系统或退出"} ?? "助手确认已交回系统控制"
            notify(received != nil,detail,token:token)
            if received==nil {
                lock.lock()
                if fd==channel && generation==token{fd = -1;timer?.cancel();timer=nil;SLFanDisconnect(channel)}
                lock.unlock();return
            }
        }
    }
    private func armTimeout(token:Int,id:UInt32) {
        let item=DispatchWorkItem{[weak self] in self?.fail("请求超时；已断开租约，助手会尝试交回系统控制。",token:token,request:id)}
        lock.lock();guard generation==token && fd>=0 && pending != nil && pendingID==id else{lock.unlock();item.cancel();return}
        timeout?.cancel();timeout=item;lock.unlock();DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+20,execute:item)
    }
    /// Removal is an explicit settings action; restore must be confirmed first.
    func uninstall(completion:@escaping Completion) {
        lock.lock();let busy=starting || pending != nil;lock.unlock()
        guard !busy else {finish(completion,.failure(.init(message:"请等待当前风扇请求结束后再卸载。")));return}
        let remove:()->Void = { [weak self] in
            guard let self else{return}
            self.shutdown()
            self.worker.async {
                let result=self.helperPath.withCString { SLFanRemoveInstalledHelper($0) }
                let reason=String(cString:SLFanLastServiceError())
                self.finish(completion,result==0 ? .success(()) : .failure(.init(message:result == -60006 ? "已取消卸载授权。" : "助手卸载未确认（状态 \(result)）：\(reason)")))
            }
        }
        if boostActive {
            restoreSystemControl { [weak self] result in
                switch result {case .success:remove();case .failure: self?.finish(completion,result)}
            }
        } else {remove()}
    }
    private func fail(_ reason:String,token:Int,request:UInt32?=nil) {
        lock.lock();guard generation==token && (request==nil || (pending != nil && pendingID==request)) else{lock.unlock();return}
        let channel=fd;fd = -1;starting=false;confirmedTargets=nil;timer?.cancel();timer=nil;timeout?.cancel();timeout=nil
        let callback=pending;pending=nil;pendingTargets=nil;lock.unlock()
        if channel>=0{SLFanDisconnect(channel)};if let callback{finish(callback,.failure(.init(message:reason)))};notify(false,reason,token:token)
    }
    private func notify(_ active:Bool,_ detail:String,token:Int) {
        DispatchQueue.main.async{[weak self] in
            guard let self else{return};self.lock.lock();let valid=self.generation==token;self.lock.unlock()
            if valid{self.onStateChange?(active,detail)}
        }
    }
    /// Disconnecting expires the helper's lease; return does not confirm a hardware write.
    func shutdown() {
        lock.lock();closed=true;generation+=1
        if fd>=0{_ = sendLocked("SYSTEM 4294967295\n")}
        let channel=fd;fd = -1;confirmedTargets=nil;timer?.cancel();timer=nil;timeout?.cancel();timeout=nil
        let callback=pending;pending=nil;pendingTargets=nil;lock.unlock()
        if channel>=0{SLFanDisconnect(channel)};if let callback{finish(callback,.failure(.init(message:"控制会话已关闭；助手将尝试交回系统控制。")))}
    }
    deinit{shutdown()}
    #if SL_FAN_TESTING
    func testSession(_ channel:Int32,generation:Int){lock.lock();fd=channel;self.generation=generation;lock.unlock()}
    func testFailure(token:Int){fail("test",token:token)}
    func testChannel()->Int32{lock.lock();defer{lock.unlock()};return fd}
    func testACKSession(_ channel:Int32, id:UInt32, targets:[Int:Double]) {
        lock.lock();fd=channel;generation=10;pendingID=id;pendingTargets=targets;pending={_ in};lock.unlock()
        worker.async{self.readMessages(channel,token:10)}
    }
    #endif
    private func finish(_ completion:@escaping Completion,_ result:Result<Void,FanControlError>){DispatchQueue.main.async{completion(result)}}
}
