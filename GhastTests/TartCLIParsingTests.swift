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

        #expect(entries.map(\.name) == ["ghast-r1-a1b2c3", "ghcr.io/cirruslabs/macos-tahoe-base:latest"])
        #expect(entries.map(\.source) == ["local", "OCI"])
        #expect(entries.map(\.isRunning) == [true, false])
    }

    /// Live format (Tart 2.42.0): ISO 8601 with a `Z` and no fractional seconds.
    @Test("list decodes size, disk and the last-used time")
    func listSizes() throws {
        let json = """
        [{"Name":"ghcr.io/cirruslabs/macos-tahoe-xcode@sha256:923c98d32e40ffadb6e6815a9722124b7a57bdf7d7763a708a2b28d1970831bd","Disk":140,"Size":87,"Accessed":"2026-11-26T00:21:01Z","Running":false,"Source":"OCI","State":"stopped"}]
        """

        let entry = try #require(try TartJSON.decodeList(Data(json.utf8)).first)

        #expect(entry.sizeGB == 87)
        #expect(entry.diskGB == 140)
        #expect(entry.accessed == Date(timeIntervalSince1970: 1_795_652_461))
    }

    @Test("a list row without Size, Disk or Accessed still decodes")
    func listWithoutSizes() throws {
        let json = #"[{"Source":"local","Name":"dev","Running":false}]"#

        let entry = try #require(try TartJSON.decodeList(Data(json.utf8)).first)

        #expect(entry == TartVMEntry(name: "dev", source: "local", isRunning: false))
        #expect(entry.sizeGB == nil && entry.diskGB == nil && entry.accessed == nil)
    }

    @Test("an unreadable Accessed leaves the date empty instead of failing the list")
    func listBadAccessed() throws {
        let json = #"[{"Source":"OCI","Name":"x","Size":3,"Accessed":"yesterday","Running":false}]"#

        let entry = try #require(try TartJSON.decodeList(Data(json.utf8)).first)

        #expect(entry.accessed == nil)
        #expect(entry.sizeGB == 3)
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

    @Test("get decodes CPU, memory in MB and disk for the image defaults")
    func getInfo() throws {
        let json = #"{"Running":false,"State":"stopped","DiskFormat":"raw","Disk":140,"CPU":4,"MACAddress":"9e:df:0d:1a:6f:d2","Memory":8192,"OS":"darwin","Size":"32.673","Display":"1024x768"}"#

        let info = try TartJSON.decodeInfo(Data(json.utf8))

        #expect(info == TartVMInfo(cpuCount: 4, memoryMB: 8192, diskGB: 140))
    }

    @Test("get without a Disk still decodes CPU and memory")
    func getInfoWithoutDisk() throws {
        let json = #"{"OS":"darwin","CPU":2,"Memory":4096}"#

        #expect(try TartJSON.decodeInfo(Data(json.utf8)) == TartVMInfo(cpuCount: 2, memoryMB: 4096, diskGB: nil))
    }

    @Test("get without CPU or Memory throws")
    func getInfoMissing() {
        #expect(throws: (any Error).self) { try TartJSON.decodeInfo(Data(#"{"OS":"darwin","Disk":50}"#.utf8)) }
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

    @Test("an isolated run blocks the host except DNS, and the cache port when the cache is on; a shared run has no rules")
    func runSoftnetArguments() {
        let share = TartShare(name: "ghast", path: URL(fileURLWithPath: "/x"), isReadOnly: true)

        #expect(TartArguments.run("vm1", shares: [share], network: .shared) == [
            "run", "--no-graphics", "--dir=ghast:/x:ro", "vm1",
        ])
        #expect(TartArguments.run("vm1", shares: [share], network: .softnet(helperDirectory: "/usr/local/libexec/ghast")) == [
            "run", "--no-graphics", "--net-softnet", "--net-softnet-block", "@host",
            "--net-softnet-allow", "out proto udp @host port 53", "--dir=ghast:/x:ro", "vm1",
        ])
        #expect(TartArguments.run("vm1", shares: [share], network: .softnet(helperDirectory: "/h", cachePort: 50123)) == [
            "run", "--no-graphics", "--net-softnet", "--net-softnet-block", "@host",
            "--net-softnet-allow", "out proto udp @host port 53,out proto tcp @host port 50123", "--dir=ghast:/x:ro", "vm1",
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
