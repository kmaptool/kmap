import XCTest

@testable import kmap

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Finding a region's extract when the mirror's `-latest` alias is not served. Over two
/// days it redirected to itself, answered 502 and then hung, as did the page listing the
/// files, while the dated files the proxies held went on answering.
final class ExtractLocatorTests: XCTestCase {
    private let latest = URL(string: "https://download.geofabrik.de/russia/crimean-fed-district-latest.osm.pbf")!
    private let today = ISO8601DateFormatter().date(from: "2026-10-01T09:00:00Z")!

    private static func info(_ url: URL) -> Downloader.RemoteInfo {
        Downloader.RemoteInfo(finalURL: url, size: 100, acceptsRanges: true, lastModified: "then")
    }

    func testTheDatedNamesRunBackFromTodayInUTC() {
        let early = ISO8601DateFormatter().date(from: "2026-03-01T00:30:00Z")!
        XCTAssertEqual(
            ExtractLocator.datedFiles(for: latest, today: early).prefix(3).map(\.lastPathComponent),
            [
                "crimean-fed-district-260301.osm.pbf", "crimean-fed-district-260228.osm.pbf",
                "crimean-fed-district-260227.osm.pbf"
            ]
        )
        XCTAssertEqual(ExtractLocator.datedFiles(for: latest, today: early).count, 7)
        XCTAssertTrue(ExtractLocator.datedFiles(for: URL(string: "https://example.org/some.osm.pbf")!).isEmpty)
    }

    func testAWorkingAliasIsTakenAsItIsAndNothingElseIsAsked() async throws {
        let asked = Locked<[String]>([])
        let found = try await ExtractLocator.locate(latest, today: today) { url, _ in
            asked.withLock { $0.append(url.lastPathComponent) }
            return Self.info(url)
        }
        XCTAssertEqual(found.url, latest)
        XCTAssertNil(found.standIn)
        XCTAssertEqual(found.md5?.lastPathComponent, "crimean-fed-district-latest.osm.pbf.md5")
        XCTAssertEqual(asked.withLock { $0 }, ["crimean-fed-district-latest.osm.pbf"])
    }

    /// Proxies keep the alias's redirect and its checksum apart around a publish, so the
    /// file and its checksum are both asked by the dated name it redirects to.
    func testTheDatedFileTheAliasLeadsToIsFetchedAndCheckedByItsName() async throws {
        let dated = latest.deletingLastPathComponent().appendingPathComponent("crimean-fed-district-261003.osm.pbf")
        let found = try await ExtractLocator.locate(latest, today: today) { _, _ in
            Downloader.RemoteInfo(finalURL: dated, size: 100, acceptsRanges: true, lastModified: "then")
        }
        XCTAssertEqual(found.url, dated)
        XCTAssertEqual(found.md5?.lastPathComponent, "crimean-fed-district-261003.osm.pbf.md5")
        XCTAssertNil(found.standIn)

        // A redirect to another host under the same name is the alias still.
        let mirror = URL(string: "https://mirror.example/crimean-fed-district-latest.osm.pbf")!
        let moved = try await ExtractLocator.locate(latest, today: today) { _, _ in
            Downloader.RemoteInfo(finalURL: mirror, size: 100, acceptsRanges: true, lastModified: "then")
        }
        XCTAssertEqual(moved.url, latest)
        XCTAssertFalse(
            ExtractLocator.isDated(URL(string: "https://x/crimean-fed-district-2610.osm.pbf")!, standingFor: latest)
        )
    }

    func testAnAliasThatLoopsGivesWayToTheNewestDatedFileThatAnswers() async throws {
        // 1 October 2026: no file for the day yet, the one for the 30th looped as well,
        // the 29th and the 28th were there.
        let found = try await ExtractLocator.locate(latest, today: today) { url, _ in
            let name = url.lastPathComponent
            if name.contains("260929") || name.contains("260928") { return Self.info(url) }
            throw URLError(.httpTooManyRedirects)
        }
        XCTAssertEqual(found.url.lastPathComponent, "crimean-fed-district-260929.osm.pbf")
        XCTAssertEqual(found.standIn, "crimean-fed-district-260929.osm.pbf")
        XCTAssertEqual(found.md5?.lastPathComponent, "crimean-fed-district-260929.osm.pbf.md5")
    }

    func testAnAliasThatHangsIsWorkedRoundToo() async throws {
        // Later the same day the alias no longer looped: it never answered at all.
        let found = try await ExtractLocator.locate(latest, today: today) { url, _ in
            if url.lastPathComponent.contains("260929") { return Self.info(url) }
            throw URLError(.timedOut)
        }
        XCTAssertEqual(found.standIn, "crimean-fed-district-260929.osm.pbf")
    }

    func testTheDatedNamesAreAskedTogetherAndBriefly() async throws {
        let waits = Locked<[String: TimeInterval]>([:])
        _ = try await ExtractLocator.locate(latest, today: today) { url, timeout in
            waits.withLock { $0[url.lastPathComponent] = timeout }
            if url.lastPathComponent.contains("260925") { return Self.info(url) }
            throw DownloadError.badStatus(502)
        }
        let asked = waits.withLock { $0 }
        XCTAssertEqual(asked.count, 8, "the alias and seven days")
        XCTAssertLessThanOrEqual(asked.values.max() ?? 99, 8, "a hanging mirror is not waited on for long")
    }

    func testOneDroppedRoundIsAskedAgainBeforeGivingUp() async throws {
        let calls = Locked(0)
        let pauses = Locked<[Int]>([])
        let found = try await ExtractLocator.locate(
            latest,
            today: today,
            probe: { url, _ in
                let round = calls.withLock { count -> Int in
                    count += 1; return (count - 1) / 8
                }
                if round == 0 { throw URLError(.networkConnectionLost) }
                return Self.info(url)
            },
            pause: { round in pauses.withLock { $0.append(round) } }
        )
        XCTAssertEqual(found.url, latest, "the second round found the alias working")
        XCTAssertEqual(pauses.withLock { $0 }, [1])
    }

    func testARegionThatIsGoneIsNotAskedForAgain() async {
        // The alias and every dated name answer 404: final, and 3 rounds of it would
        // only say so 6 seconds later.
        let calls = Locked(0)
        let pauses = Locked(0)
        do {
            _ = try await ExtractLocator.locate(
                latest,
                today: today,
                probe: { _, _ in
                    calls.withLock { $0 += 1 }
                    throw DownloadError.badStatus(404)
                },
                pause: { _ in pauses.withLock { $0 += 1 } }
            )
            XCTFail("nothing is there")
        } catch {
            guard case DownloadError.badStatus(404) = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(calls.withLock { $0 }, 8, "the alias and seven days, once")
        XCTAssertEqual(pauses.withLock { $0 }, 0)
    }

    func testTheLikeliestDaysAreAskedFirstAndTheRestOnlyIfNeeded() async throws {
        let asked = Locked<[String]>([])
        let found = try await ExtractLocator.locate(latest, today: today) { url, _ in
            asked.withLock { $0.append(url.lastPathComponent) }
            if url.lastPathComponent.contains("260929") { return Self.info(url) }
            throw URLError(.httpTooManyRedirects)
        }
        XCTAssertEqual(found.standIn, "crimean-fed-district-260929.osm.pbf")
        XCTAssertEqual(asked.withLock { $0 }.count, 4, "the alias and the three newest days")
    }

    func testAThrottledMirrorIsGivenALongerPauseAndNoBurst() async throws {
        let calls = Locked<[String]>([])
        let pauses = Locked<[Int]>([])
        let found = try await ExtractLocator.locate(
            latest,
            today: today,
            probe: { url, _ in
                let n = calls.withLock { list -> Int in
                    list.append(url.lastPathComponent); return list.count
                }
                if n == 1 { throw DownloadError.badStatus(429) }
                return Self.info(url)
            },
            pause: { round in pauses.withLock { $0.append(round) } }
        )
        XCTAssertEqual(found.url, latest)
        XCTAssertEqual(calls.withLock { $0 }.count, 2, "a 429 on the alias sends no dated requests")
        XCTAssertEqual(pauses.withLock { $0 }, [3])
    }

    func testAMirrorThatAnswersNothingReportsTheAliasError() async {
        let calls = Locked(0)
        do {
            _ = try await ExtractLocator.locate(
                latest,
                today: today,
                probe: { url, _ in
                    calls.withLock { $0 += 1 }
                    if url.lastPathComponent.contains("latest") { throw URLError(.timedOut) }
                    throw DownloadError.badStatus(404)
                },
                pause: { _ in }
            )
            XCTFail("nothing answers")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(calls.withLock { $0 }, 24, "three rounds of the alias and seven days")
    }
}
