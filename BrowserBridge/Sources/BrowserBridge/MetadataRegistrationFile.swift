import Foundation
import Darwin

/// Public registrations only, under an app-owned 0700 directory selected by
/// the containing app. No default path, import from wire, private key or grant.
public final class MetadataRegistrationFile {
    private let directory: URL
    public init(directory: URL) throws {
        var info=stat()
        guard lstat(directory.path,&info)==0,(info.st_mode&S_IFMT)==S_IFDIR,
              info.st_uid==geteuid(),info.st_mode&0o077==0 else {throw MetadataEnrollmentError.invalid}
        self.directory=directory
    }
    private func locked<T>(_ body:()throws->T)throws->T {
        let fd=open(directory.appendingPathComponent("registrations.lock").path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        guard fd>=0 else {throw MetadataEnrollmentError.invalid};defer{Darwin.close(fd)}
        guard flock(fd,LOCK_EX)==0 else {throw MetadataEnrollmentError.invalid};defer{flock(fd,LOCK_UN)}
        return try body()
    }
    private func records()throws->[MetadataRegistration] {
        let path=directory.appendingPathComponent("registrations.json").path
        let fd=open(path,O_RDONLY|O_NOFOLLOW)
        if fd<0 && errno==ENOENT{return []}
        guard fd>=0 else {throw MetadataEnrollmentError.invalid};defer{Darwin.close(fd)}
        var info=stat()
        guard fstat(fd,&info)==0,info.st_uid==geteuid(),info.st_mode&0o077==0,(info.st_mode&S_IFMT)==S_IFREG,
              info.st_size>0,info.st_size<=16_384 else {throw MetadataEnrollmentError.invalid}
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:false)
        let rows=try JSONDecoder().decode([MetadataRegistration].self,from:handle.read(upToCount:16_385) ?? Data())
        guard rows.count<=2 else {throw MetadataEnrollmentError.invalid}
        for row in rows {
            guard try MetadataRegistration(browser:row.browser,extensionID:row.extensionID,publicKey:row.publicKey)==row else {throw MetadataEnrollmentError.invalid}
        }
        guard Set(rows.map{$0.browser.rawValue}).count==rows.count else {throw MetadataEnrollmentError.invalid}
        return rows
    }
    public func load(browser:MetadataBrowser,extensionID:String)throws->MetadataRegistration? {
        try locked {
            if let found=try records().first(where:{$0.browser==browser}) {
                guard found.extensionID==extensionID else {throw MetadataEnrollmentError.changedPin};return found
            };return nil
        }
    }
    public func save(_ record:MetadataRegistration)throws {
        try locked {
            guard try MetadataRegistration(browser:record.browser,extensionID:record.extensionID,publicKey:record.publicKey)==record else {throw MetadataEnrollmentError.invalid}
            var rows=try records()
            if let old=rows.first(where:{$0.browser==record.browser}) {
                guard old==record else {throw MetadataEnrollmentError.changedPin};return
            }
            rows.append(record)
            let path=directory.appendingPathComponent("registrations.json")
            // The temporary inode is private from creation, before rename.
            let temporary=directory.appendingPathComponent(".registration-"+UUID().uuidString)
            let fd=open(temporary.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
            guard fd>=0 else {throw MetadataEnrollmentError.invalid}
            let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
            do {
                try handle.write(contentsOf:JSONEncoder().encode(rows));try handle.synchronize();try handle.close()
                guard rename(temporary.path,path.path)==0 else {throw MetadataEnrollmentError.invalid}
            } catch {try? handle.close();try? FileManager.default.removeItem(at:temporary);throw error}
        }
    }
}
