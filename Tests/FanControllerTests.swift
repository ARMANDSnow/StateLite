import Foundation
import Darwin
@main struct FanControllerTests {
    static func main() {
        var pipes:[Int32]=[0,0]
        precondition(pipe(&pipes)==0)
        let controller=FanController()
        controller.testSession(pipes[0],generation:2)
        controller.testFailure(token:1)
        precondition(controller.testChannel()==pipes[0],"old reader/timeout must not close new session")
        precondition(fcntl(pipes[0],F_GETFD)>=0)
        controller.testFailure(token:2)
        precondition(controller.testChannel()==(-1),"current error must disconnect lease")
        precondition(fcntl(pipes[0],F_GETFD)==(-1))
        close(pipes[1]);controller.shutdown()
        var sockets:[Int32]=[0,0];precondition(socketpair(AF_UNIX,SOCK_STREAM,0,&sockets)==0)
        let ackController=FanController();ackController.testACKSession(sockets[0],id:9,targets:[0:3000,1:3500])
        func send(_ line:String){line.withCString{precondition(write(sockets[1],$0,strlen($0))>0)}}
        send("ACK 8 TARGETS 0=3000.00 1=3500.00\n")
        Thread.sleep(forTimeInterval:0.05);precondition(!ackController.boostActive,"stale ACK must not confirm a new request")
        send("ACK 9 TARGETS 0=3000.00 1=3500.00\n")
        for _ in 0..<50 {if ackController.boostActive{break};Thread.sleep(forTimeInterval:0.01)}
        precondition(ackController.targetsRPM==[0:3000,1:3500],"matching ACK confirms exact per-fan targets")
        ackController.shutdown();close(sockets[1])
        var blocked:[Int32]=[0,0];precondition(socketpair(AF_UNIX,SOCK_STREAM,0,&blocked)==0)
        let flags=fcntl(blocked[0],F_GETFL);precondition(fcntl(blocked[0],F_SETFL,flags|O_NONBLOCK)==0)
        let fill=[UInt8](repeating:65,count:4096)
        while fill.withUnsafeBytes({write(blocked[0],$0.baseAddress,$0.count)})>0 {}
        let start=Date();let result="PING\n".withCString{SLFanSendCommand(blocked[0],$0)}
        precondition(result<0 && Date().timeIntervalSince(start)<0.8,"full IPC buffer must fail within a bounded deadline")
        close(blocked[0]);close(blocked[1])
        print("Fan controller stale-generation and stale-ACK isolation passed; no helper launch or hardware access.")
    }
}
