import Testing
import Foundation
@testable import Ghast

@Suite("Tart CLI arguments and JSON")
struct TartCLIParsingTests {
    @Test("list decodes name, source and running state")
    func listJSON() throws {
        let json = """
        [{"Source":"local","Name":"ghast-r1-a1b2c3","Disk":50,"Size":20,"Accessed":"2026-11-18T10:00:00Z","Running":true,"State":"running"},
         {"Source":"OCI","Name":"ghcr.io/cirruslabs/macos-tahoe-base:latest","Disk":50,"Size":25,"Accessed":"2026-11-18T09:00:00Z","Running":false,"State":"stopped"}]
        """

        let entries = try TartJSON.decodeList(Data(json.utf8))

        #expect(entries == [
            TartVMEntry(name: "ghast-r1-a1b2c3", source: "local", isRunning: true),
            TartVMEntry(name: "ghcr.io/cirruslabs/macos-tahoe-base:latest", source: "OCI", isRunning: false),
        ])
    }

    @Test("get decodes the guest OS")
    func getJSON() throws {
        let json = #"{"OS":"darwin","CPU":4,"Memory":8192,"Disk":50,"DiskFormat":"asif","Size":"20","Display":"1024x768px","MACAddress":"aa","Running":true,"State":"running"}"#

        #expect(try TartJSON.decodeOS(Data(json.utf8)) == "darwin")
    }

    /// Live Step 0b sample: `get` reports Size as a string where `list` reports an integer.
    @Test("get decodes the real reply, whose Size is a string")
    func getRealSample() throws {
        let json = #"{"Running":false,"State":"stopped","DiskFormat":"raw","Disk":50,"CPU":4,"MACAddress":"9e:df:0d:1a:6f:d2","Memory":8192,"OS":"darwin","Size":"32.673","Display":"1024x768"}"#

        #expect(try TartJSON.decodeOS(Data(json.utf8)) == "darwin")
    }

    /// Live Step 0b shape: a pulled image is listed by tag and again by digest (digest value is
    /// illustrative; the real one only differs in the hex).
    @Test("a pulled image listed by tag and by digest decodes as two OCI entries")
    func listTagAndDigest() throws {
        let digest = "ghcr.io/cirruslabs/macos-tahoe-base@sha256:" + String(repeating: "ab", count: 32)
        let json = """
        [{"Source":"OCI","Name":"ghcr.io/cirruslabs/macos-tahoe-base:latest","Disk":50,"Size":33,"Accessed":"2026-11-18T09:00:00Z","Running":false,"State":"stopped"},
         {"Source":"OCI","Name":"\(digest)","Disk":50,"Size":33,"Accessed":"2026-11-18T09:00:00Z","Running":false,"State":"stopped"}]
        """

        let entries = try TartJSON.decodeList(Data(json.utf8))

        #expect(entries.map(\.name) == ["ghcr.io/cirruslabs/macos-tahoe-base:latest", digest])
        #expect(entries.allSatisfy { $0.source == "OCI" && !$0.isRunning })
    }

    @Test("malformed JSON throws instead of reading as an empty list")
    func malformed() {
        #expect(throws: (any Error).self) { try TartJSON.decodeList(Data("not json".utf8)) }
    }

    @Test("run is headless, shares read-only folders as name:path:ro, and ends with the VM name")
    func runArguments() {
        let shares = [
            TartShare(name: "ghast", path: URL(fileURLWithPath: "/Users/x/.ghast/tart-cache"), isReadOnly: true),
            TartShare(name: "out", path: URL(fileURLWithPath: "/tmp/out"), isReadOnly: false),
        ]

        #expect(TartArguments.run("vm1", shares: shares, network: .shared) == [
            "run", "--no-graphics",
            "--dir=ghast:/Users/x/.ghast/tart-cache:ro",
            "--dir=out:/tmp/out",
            "vm1",
        ])
    }

    @Test("run adds --net-softnet right after --no-graphics only when isolated")
    func runSoftnetArguments() {
        let share = TartShare(name: "ghast", path: URL(fileURLWithPath: "/x"), isReadOnly: true)

        #expect(TartArguments.run("vm1", shares: [share], network: .shared) == [
            "run", "--no-graphics", "--dir=ghast:/x:ro", "vm1",
        ])
        #expect(TartArguments.run("vm1", shares: [share], network: .softnet(helperDirectory: "/usr/local/libexec/ghast")) == [
            "run", "--no-graphics", "--net-softnet", "--dir=ghast:/x:ro", "vm1",
        ])
    }

    @Test("set passes only the flags that are set", arguments: [
        (VMResources(cpuCount: 8), ["set", "vm1", "--cpu", "8"] as [String]?),
        (VMResources(memoryGB: 16), ["set", "vm1", "--memory", "16384"]),
        (VMResources(diskGB: 150), ["set", "vm1", "--disk-size", "150"]),
        (VMResources(cpuCount: 8, memoryGB: 16, diskGB: 150), ["set", "vm1", "--cpu", "8", "--memory", "16384", "--disk-size", "150"]),
        (VMResources.empty, nil),
        (VMResources(isNetworkIsolated: true), nil),
    ])
    func setArguments(resources: VMResources, expected: [String]?) {
        #expect(TartArguments.set("vm1", resources: resources) == expected)
    }

    /// Live spike sample (Tart 2.42.0): `Disk` is whole GB, `Size` the used size as a string.
    @Test("get decodes the disk size")
    func getDiskSize() throws {
        let json = #"{"Memory":16384,"DiskFormat":"raw","Display":"1024x768","Disk":150,"CPU":8,"Size":"32.673","Running":false,"State":"stopped","MACAddress":"9e:df:0d:1a:6f:d2","OS":"darwin"}"#

        #expect(try TartJSON.decodeDiskSize(Data(json.utf8)) == 150)
    }

    @Test("exec puts the VM before the guest command, which is passed through untouched")
    func execArguments() {
        #expect(TartArguments.exec("vm1", ["/bin/bash", "-c", "echo 'a b'; exit 3"]) == [
            "exec", "vm1", "/bin/bash", "-c", "echo 'a b'; exit 3",
        ])
    }

    @Test("the simple commands")
    func simpleArguments() {
        #expect(TartArguments.list == ["list", "--format", "json"])
        #expect(TartArguments.get("vm1") == ["get", "vm1", "--format", "json"])
        #expect(TartArguments.pull("ghcr.io/x/y:latest") == ["pull", "ghcr.io/x/y:latest"])
        #expect(TartArguments.clone("src", "dst") == ["clone", "src", "dst"])
        #expect(TartArguments.stop("vm1", timeout: 8) == ["stop", "vm1", "--timeout", "8"])
        #expect(TartArguments.delete("vm1") == ["delete", "vm1"])
    }
}
