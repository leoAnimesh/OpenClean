import Foundation
import OpenCleanKit
import TestSupport
import Testing

struct DisplayCacheTests {
    @Test func roundTripsAValueWithItsDate() throws {
        let temp = try TempDirectory()
        let cache = DisplayCache(directory: URL(fileURLWithPath: temp.path + "/Cache"))
        #expect(cache.load([String].self, .installedApps) == nil)
        let now = Date(timeIntervalSince1970: 1_000_000)
        cache.save(["a", "b"], .installedApps, now: now)
        let loaded = try #require(cache.load([String].self, .installedApps))
        #expect(loaded.value == ["a", "b"])
        #expect(loaded.savedAt == now)
        #expect(cache.load([String].self, .loginItems) == nil, "entries are separate files")
    }

    @Test func unreadableOrOtherVersionFilesAreNoCache() throws {
        let temp = try TempDirectory()
        let directory = try temp.directory("Cache")
        let cache = DisplayCache(directory: URL(fileURLWithPath: directory))
        try Data("not json".utf8).write(to: URL(fileURLWithPath: directory + "/installed-apps.json"))
        #expect(cache.load([String].self, .installedApps) == nil)

        let other = #"{"version":999,"savedAt":0,"value":["a"]}"#
        try Data(other.utf8).write(to: URL(fileURLWithPath: directory + "/installed-apps.json"))
        #expect(cache.load([String].self, .installedApps) == nil)

        cache.save([1, 2], .installedApps)
        #expect(cache.load([String].self, .installedApps) == nil, "a different shape is no cache")
    }
}
