import CoreMedia
import Foundation

/// JSON representation of a `CMTime` as an exact rational number, since
/// CoreMedia types are not `Codable`.
struct CodableTime: Codable {
    var value: Int64
    var timescale: Int32

    init(_ time: CMTime) {
        value = time.value
        timescale = time.timescale
    }

    var time: CMTime { CMTime(value: value, timescale: timescale) }
}

struct CodableTimeRange: Codable {
    var start: CodableTime
    var duration: CodableTime

    init(_ range: CMTimeRange) {
        start = CodableTime(range.start)
        duration = CodableTime(range.duration)
    }

    var range: CMTimeRange { CMTimeRange(start: start.time, duration: duration.time) }
}

extension KeyedEncodingContainer {
    mutating func encode(_ time: CMTime, forKey key: Key) throws {
        try encode(CodableTime(time), forKey: key)
    }

    mutating func encode(_ range: CMTimeRange, forKey key: Key) throws {
        try encode(CodableTimeRange(range), forKey: key)
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: CMTime.Type, forKey key: Key) throws -> CMTime {
        try decode(CodableTime.self, forKey: key).time
    }

    func decode(_ type: CMTimeRange.Type, forKey key: Key) throws -> CMTimeRange {
        try decode(CodableTimeRange.self, forKey: key).range
    }
}
