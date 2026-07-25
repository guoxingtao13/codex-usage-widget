import Foundation

actor CodexUsageScanner {
  private let fileManager = FileManager.default
  private let maximumFileBytes: UInt64 = 4 * 1_024 * 1_024
  private let maximumCandidateFiles = 20
  private var cache: [URL: CachedSnapshot] = [:]
  private var newestKnownSnapshot: UsageSnapshot?

  func latestSnapshot() -> UsageSnapshot? {
    let candidates = recentSessionDirectories()
      .flatMap(filesDirectlyInside)
      .sorted { $0.modificationDate > $1.modificationDate }
      .prefix(maximumCandidateFiles)

    let activeURLs = Set(candidates.map(\.url))
    cache = cache.filter { activeURLs.contains($0.key) }

    for candidate in candidates {
      if let cached = cache[candidate.url],
        cached.fileSize == candidate.fileSize,
        cached.modificationDate == candidate.modificationDate
      {
        continue
      }

      guard let data = readTail(of: candidate.url),
        let snapshot = UsageLogParser.latestSnapshot(
          in: data,
          sourcePath: candidate.url.path
        )
      else {
        continue
      }

      cache[candidate.url] = CachedSnapshot(
        fileSize: candidate.fileSize,
        modificationDate: candidate.modificationDate,
        snapshot: snapshot
      )

      if newestKnownSnapshot == nil || snapshot.timestamp > newestKnownSnapshot!.timestamp {
        newestKnownSnapshot = snapshot
      }
    }

    return newestKnownSnapshot
  }

  private func recentSessionDirectories() -> [URL] {
    let root = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex/sessions", isDirectory: true)
    let calendar = Calendar.current

    return (0..<7).compactMap { daysAgo in
      guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) else {
        return nil
      }

      let components = calendar.dateComponents([.year, .month, .day], from: date)
      guard let year = components.year,
        let month = components.month,
        let day = components.day
      else {
        return nil
      }

      return
        root
        .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
        .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
        .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
    }
  }

  private func filesDirectlyInside(_ directory: URL) -> [CandidateFile] {
    guard
      let urls = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [
          .contentModificationDateKey,
          .fileSizeKey,
          .isRegularFileKey,
        ],
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }

    var result: [CandidateFile] = []
    for url in urls where url.pathExtension == "jsonl" {
      guard
        let values = try? url.resourceValues(
          forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        ),
        values.isRegularFile == true
      else {
        continue
      }

      result.append(
        CandidateFile(
          url: url,
          modificationDate: values.contentModificationDate ?? .distantPast,
          fileSize: UInt64(max(0, values.fileSize ?? 0))
        )
      )
    }
    return result
  }

  private func readTail(of url: URL) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: url) else {
      return nil
    }
    defer {
      try? handle.close()
    }

    guard let size = try? handle.seekToEnd() else {
      return nil
    }

    let startOffset = size > maximumFileBytes ? size - maximumFileBytes : 0
    do {
      try handle.seek(toOffset: startOffset)
      guard var data = try handle.readToEnd() else {
        return nil
      }

      if startOffset > 0,
        let newline = data.firstIndex(of: 0x0A)
      {
        data.removeSubrange(data.startIndex...newline)
      }
      return data
    } catch {
      return nil
    }
  }
}

private struct CandidateFile {
  let url: URL
  let modificationDate: Date
  let fileSize: UInt64
}

private struct CachedSnapshot {
  let fileSize: UInt64
  let modificationDate: Date
  let snapshot: UsageSnapshot
}

@MainActor
final class CodexUsageMonitor {
  private let scanner = CodexUsageScanner()
  private let onUpdate: (UsageSnapshot?) -> Void
  private var timer: Timer?
  private var isRefreshing = false

  init(onUpdate: @escaping (UsageSnapshot?) -> Void) {
    self.onUpdate = onUpdate
  }

  func start() {
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.refresh()
      }
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  func refresh() {
    guard !isRefreshing else {
      return
    }
    isRefreshing = true

    Task {
      let snapshot = await scanner.latestSnapshot()

      isRefreshing = false
      onUpdate(snapshot)
    }
  }
}
