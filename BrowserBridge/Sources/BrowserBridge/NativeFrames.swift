import Foundation

public enum NativeFrameError:Error {case truncated,oversized,malformed}
/// Chrome native messaging uses a native-endian UInt32 byte count. The bridge
/// accepts only 4KiB, rejecting the header before allocating/reading its body.
public enum NativeFrames {
    public static let limit=4096
    public static func encode(_ data:Data)throws->Data {
        guard !data.isEmpty,data.count<=limit else {throw NativeFrameError.oversized}
        var size=UInt32(data.count)
        var result=withUnsafeBytes(of:&size) {Data($0)};result.append(data);return result
    }
    public static func read(from input:FileHandle)throws->Data? {
        func exact(_ count:Int)throws->Data {
            var result=Data()
            while result.count<count {
                guard let bytes=try input.read(upToCount:count-result.count),!bytes.isEmpty else {throw NativeFrameError.truncated}
                result.append(bytes)
            }
            return result
        }
        guard let first=try input.read(upToCount:1),!first.isEmpty else {return nil}
        var header=first;header.append(try exact(3))
        var size:UInt32=0
        _=withUnsafeMutableBytes(of:&size) {header.copyBytes(to:$0)}
        guard size>0,size<=limit else {throw NativeFrameError.oversized}
        return try exact(Int(size))
    }
}
