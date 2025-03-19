// The Swift Programming Language
// https://docs.swift.org/swift-book

import ZipArchive


//
//  MyDownloadManager.swift
//  TestAppSwift6
//
//  Created by Mac14 on 10/03/25.
//

import Foundation
import ZipArchive

public let fidentifier = "com.hns.HDownloadManger"// "com.hns.Dom"
public let fbundle = Bundle(identifier: fidentifier)

public struct MyDownload {
    var fileSavePath: String?
    var fileUrl: URL?
    var needUnzip = false
    var downloadstate:DownloadState = .notstarted
}

public enum DownloadState {
    case notstarted
    case waiting
    case downloading
    case paused
    case resumed
    case canceled
    case downloaded
    case failed
    case unzipping
    case unziped
}

public enum DownloadMode {
    case serial
    case concurrent
}

let maxDownloadCount = 3


@MainActor open class MyDownloadManager: NSObject, URLSessionDelegate,URLSessionDownloadDelegate {
    static public let sharedInstance = MyDownloadManager()
    private var queueList: [MyDownload] = []
    private var downloadList: [MyDownload] = []
    private var downloadTasks: [String: URLSessionDownloadTask] = [:] // Store download tasks by URL
    private var resumedData: [String: Data] = [:]
    private var resumedByteOffsets: [String: Int64] = [:]// Store byte offset for each download
    private var totalByteOffsets: [String: Int64] = [:]// Store total byte offset for each download
    private var unzipStatus: [String: Bool] = [:]// Store unzip for each download
    private var downloadURLs: [String: URL] = [:] // Store URLs of each download
    private var urlSession: URLSession!
    var workItems: [String:DispatchWorkItem] = [:]
    var updateProgress:((_ url:URL?,_ downloadProgress:Double, _ fileSize:String, _ totalSize:String) -> ())?
    var updateSingleDownloaded:((URL?,Bool,String) -> ())?
    var updateDownloadStatus:((URL?,DownloadState) -> ())?
    var updateDownloadfailed:((URL?) -> ())?
    
    var needAutoDownload = true
    var downLoadMode:DownloadMode = .serial
    
    let serialQueue = DispatchQueue(label: "com.example.urlSession_serialQueue", qos: .background)
    let semaphore = DispatchSemaphore(value: 0)
    
    let concurrentQueue = DispatchQueue(label: "com.example.urlSession_concurrentQueue", qos: .background, attributes: .concurrent)
    let csemaphore = DispatchSemaphore(value: 3)
    let cdispatchGroup = DispatchGroup()
    override init() {
        super.init()
        loadDefaults()
    }
    
    func loadDefaults() {
        let configuration = URLSessionConfiguration.background(withIdentifier: fidentifier)
        self.urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        
        // Attempt to resume previously paused downloads
//        if needAutoDownload {
//            loadDownloadState()
//        }
    }
    func performTask() {
        // Create a DispatchWorkItem
        let workItem = DispatchWorkItem {
            // Simulate a background task
            print("Starting background task...")
            sleep(2)  // Simulate a delay
            print("Background task complete.")
            
            // Perform UI updates on the main thread
            DispatchQueue.main.async {
                print("UI updated on the main thread.")
            }
        }

        // Dispatch the work item on a background queue
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
        
        // Optionally, you can cancel the work item if needed
        // workItem.cancel()
        
        // Wait for the work item to finish if you need to handle its result
        workItem.notify(queue: DispatchQueue.main) {
            print("Work item has completed.")
        }
    }
    
    // Start downloading a file
    private func startDownload() {
        if !queueList.isEmpty {
            if self.downLoadMode == .concurrent {
                let waited = self.queueList.filter({ $0.downloadstate == .waiting || $0.downloadstate == .resumed})
                if !waited.isEmpty {
                    let url = waited.first!
                    let urlString = url.fileUrl?.absoluteString ?? ""
                    if self.downloadList.first(where: { $0.fileUrl?.absoluteString == urlString }) == nil {
                        self.concurrentQueue.async {
                            // Wait for permission from the semaphore to execute a task
                            self.csemaphore.wait()
                            Task { @MainActor in
                                if !self.queueList.isEmpty {
                                    let waited = self.queueList.filter({ $0.downloadstate == .waiting || $0.downloadstate == .resumed})
                                    if !waited.isEmpty {
                                        let url = waited.first!
                                        let urlString = url.fileUrl?.absoluteString ?? ""
                                        if self.downloadTasks[urlString] == nil {
                                            // Start the download task
                                            print("Starting Task - \(urlString)")
                                            let file = self.checkfile(name: url.fileUrl!.lastPathComponent)
                                            if file.status {
                                                let downloadings = self.queueList.filter({ $0.downloadstate == .waiting || $0.downloadstate == .resumed}).prefix(3).map { $0.fileUrl?.absoluteString }
                                                if downloadings.contains(urlString)  {
                                                    if let urlindex = self.queueList.firstIndex(where: { $0.fileUrl?.absoluteString == urlString }) {
                                                        self.queueList[urlindex].downloadstate = .unzipping
                                                    }
                                                    self.unzipMethod(urlString: urlString, source: file.source, url: url.fileUrl!)
                                                }
                                            } else {
                                                let downloadings = self.queueList.filter({ $0.downloadstate == .waiting || $0.downloadstate == .resumed}).prefix(3).map { $0.fileUrl?.absoluteString }
                                                if downloadings.contains(urlString)  {
                                                    if url.downloadstate == .resumed {
                                                        guard let resumedByteOffset = self.resumedByteOffsets[urlString] else { return }
                                                        if let resumeData = self.resumedData[urlString] {
                                                            let downloadings = self.queueList.filter({ $0.downloadstate == .waiting || $0.downloadstate == .resumed}).prefix(3).map { $0.fileUrl?.absoluteString }
                                                            if downloadings.contains(urlString)  {
                                                                let resumedTask = self.urlSession.downloadTask(withResumeData: resumeData)
                                                                resumedTask.resume()
                                                                print("Resumed downloading: \(url.fileUrl!.lastPathComponent) from byte offset: \(resumedByteOffset)")
                                                                // Store the resumed task
                                                                self.downloadTasks[urlString] = resumedTask
                                                                if let urlindex = self.queueList.firstIndex(where: { $0.fileUrl?.absoluteString == urlString }) {
                                                                    print("Resumed downloading: Started")
                                                                    self.queueList[urlindex].downloadstate = .downloading
                                                                    self.updateDownloadStatus?( url.fileUrl, .downloading)
                                                                }
                                                            } else {
                                                                print("Ending Task - \(urlString)")
                                                                self.csemaphore.signal()
                                                                self.addDownload()
                                                            }
                                                        }
                                                    } else if url.downloadstate == .paused {
                                                        print("Ending Task - \(urlString)")
                                                        self.csemaphore.signal()
                                                    } else {
                                                        let downloadTask = self.urlSession.downloadTask(with:(url.fileUrl!))
                                                        downloadTask.resume()
                                                        if let urlindex = self.queueList.firstIndex(where: { $0.fileUrl?.absoluteString == urlString }) {
                                                            print("Downloading: Started")
                                                            self.queueList[urlindex].downloadstate = .downloading
                                                            self.updateDownloadStatus?( url.fileUrl, .downloading)
                                                        }
                                                        self.downloadList.append(url)
                                                        self.downloadTasks[urlString] = downloadTask
                                                        self.downloadURLs[urlString] = url.fileUrl
                                                        self.unzipStatus[urlString] = url.needUnzip
                                                        print("Started downloading: \(url.fileUrl!.lastPathComponent)")
                                                    }
                                                } else {
                                                    print("Ending Task - \(urlString)")
                                                    self.csemaphore.signal()
                                                    self.addDownload()
                                                }
                                            }
                                        } else {
                                            print("Ending Task - \(urlString)")
                                            self.csemaphore.signal()
                                            self.addDownload()
                                        }
                                    } else {
                                        print("Ending Task - \(urlString)")
                                        self.csemaphore.signal()
                                        self.addDownload()
                                    }
                                } else {
                                    print("Ending Task - \(urlString)")
                                    self.csemaphore.signal()
                                    self.addDownload()
                                }
                            }
                        }
                    }
                }
            } else {
                let url = queueList.first!
                let urlString = url.fileUrl?.absoluteString ?? ""
                if self.downloadTasks[urlString] == nil {
                    if self.downloadList.first(where: { $0.fileUrl?.absoluteString == urlString }) == nil {
                        self.serialQueue.async {
                            Task { @MainActor in
                                if !self.queueList.isEmpty {
                                    let url = self.queueList.first!
                                    let urlString = url.fileUrl?.absoluteString ?? ""
                                    // Start the download task
                                    print("Starting Task - \(urlString)")
                                    if self.downloadTasks[urlString] == nil {
                                        let file = self.checkfile(name: url.fileUrl!.lastPathComponent)
                                        if file.status {
                                            if let urlindex = self.queueList.firstIndex(where: { $0.fileUrl?.absoluteString == urlString }) {
                                                self.queueList[urlindex].downloadstate = .unzipping
                                            }
                                            self.unzipMethod(urlString: urlString, source: file.source, url: url.fileUrl!)
                                        } else {
                                            if url.downloadstate == .resumed {
                                                guard let resumedByteOffset = self.resumedByteOffsets[urlString] else { return }
                                                if let resumeData = self.resumedData[urlString] {
                                                    if self.queueList.first?.fileUrl?.absoluteString == urlString {
                                                        let resumedTask = self.urlSession.downloadTask(withResumeData: resumeData)
                                                        resumedTask.resume()
                                                        print("Resumed downloading: \(url.fileUrl!.lastPathComponent) from byte offset: \(resumedByteOffset)")
                                                        // Store the resumed task
                                                        self.downloadTasks[urlString] = resumedTask
                                                        if let urlindex = self.queueList.firstIndex(where: { $0.fileUrl?.absoluteString == urlString }) {
                                                            print("Resumed downloading: Started")
                                                            self.queueList[urlindex].downloadstate = .downloading
                                                            self.updateDownloadStatus?( url.fileUrl, .downloading)
                                                        }
                                                    } else {
                                                        print("Ending Task - \(urlString)")
                                                        self.semaphore.signal()
                                                        self.addDownload()
                                                    }
                                                } else {
                                                    print("Ending Task - \(urlString)")
                                                    self.semaphore.signal()
                                                    self.addDownload()
                                                }
                                            } else if url.downloadstate == .paused {
                                                print("Ending Task - \(urlString)")
                                                self.semaphore.signal()
                                            } else {
                                                let downloadTask = self.urlSession.downloadTask(with:(url.fileUrl!))
                                                downloadTask.resume()
                                                if let urlindex = self.queueList.firstIndex(where: { $0.fileUrl?.absoluteString == urlString }) {
                                                    self.queueList[urlindex].downloadstate = .downloading
                                                    self.updateDownloadStatus?( url.fileUrl, .downloading)
                                                }
                                                self.downloadList.append(url)
                                                self.downloadTasks[urlString] = downloadTask
                                                self.downloadURLs[urlString] = url.fileUrl
                                                self.unzipStatus[urlString] = url.needUnzip
                                                print("Started downloading: \(url.fileUrl!.lastPathComponent)")
                                            }
                                        }
                                    } else {
                                        print("Ending Task - \(urlString)")
                                        self.semaphore.signal()
                                    }
                                } else {
                                    print("Ending Task - \(urlString)")
                                    self.semaphore.signal()
                                }
                            }
                            
                            // Wait until the current task finishes before proceeding to the next
                            self.semaphore.wait()
                        }
                    }
                }
            }
        }
        
    }
    
    private func checkfile(name: String) -> (status:Bool,source:URL) {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var destinationURL = documentsDirectory
        destinationURL.appendPathComponent(name)
        return (destinationURL.checkMyFileExist(),destinationURL)
    }
    
    func startSingleDownload(from url: MyDownload) {
        let downloadItem = url
        let urlString = url.fileUrl?.absoluteString ?? ""
        if self.queueList.first(where: { $0.fileUrl?.absoluteString == urlString }) == nil {
            if downloadItem.downloadstate == .notstarted || downloadItem.downloadstate == .paused || downloadItem.downloadstate == .canceled || downloadItem.downloadstate == .failed {
                if let lastindex = self.queueList.lastIndex(where: { $0.downloadstate == .waiting || $0.downloadstate == .resumed || $0.downloadstate == .downloading}) {
                    self.queueList.insert(url, at: lastindex+1)
                    self.queueList[lastindex+1].downloadstate = .waiting
                    self.updateDownloadStatus?( url.fileUrl, .waiting)
                } else {
                    self.queueList.append(url)
                    self.queueList[self.queueList.count-1].downloadstate = .waiting
                    self.updateDownloadStatus?(url.fileUrl, .waiting)
                }
            }
            self.addDownload()
        }
    }
    
    func startMultipleDownloads(from urls: [MyDownload]) {
        if !urls.isEmpty {
            for i in 0 ..< urls.count {
                let downloadItem = urls[i]
                let urlString = downloadItem.fileUrl?.absoluteString ?? ""
                if self.queueList.first(where: { $0.fileUrl?.absoluteString == urlString }) == nil {
                    if downloadItem.downloadstate == .notstarted || downloadItem.downloadstate == .paused || downloadItem.downloadstate == .canceled || downloadItem.downloadstate == .failed {
                        if let lastindex = self.queueList.lastIndex(where: { $0.downloadstate == .waiting || $0.downloadstate == .resumed || $0.downloadstate == .downloading}) {
                            self.queueList.insert(downloadItem, at: lastindex+1)
                            self.queueList[lastindex+1].downloadstate = .waiting
                            self.updateDownloadStatus?( downloadItem.fileUrl, .waiting)
                        } else {
                            self.queueList.append(downloadItem)
                            self.queueList[self.queueList.count-1].downloadstate = .waiting
                            self.updateDownloadStatus?( downloadItem.fileUrl, .waiting)
                        }
                    }
                }
            }
            addDownload()
        }
    }
    
    func addDownload() {
        if !self.queueList.isEmpty {
            if self.downLoadMode == .concurrent {
                let count = maxDownloadCount - self.downloadList.count
                let loopcount = self.queueList.count < count ?  self.queueList.count:count
                if loopcount == 0 {
                    self.startDownload()
                } else {
                    for _ in 0..<loopcount {
                        self.startDownload()
                    }
                }
            } else {
                self.startDownload()
            }
        }
    }
    
    
    
    // Pause a download
    func pauseDownload(from url: URL) {
        let urlString = url.absoluteString
        if let urlindex = self.queueList.firstIndex(where: { $0.fileUrl?.absoluteString == urlString }) {
            if self.queueList[urlindex].downloadstate == .downloading {
                self.queueList[urlindex].downloadstate = .paused
                let new = self.queueList[urlindex]
                print(self.queueList)
                self.queueList.remove(at: urlindex)
                self.queueList.append(new)
                print(self.queueList)
                if let nurlindex = self.downloadList.firstIndex(where: { $0.fileUrl?.absoluteString == urlString }) {
                    self.downloadList.remove(at: nurlindex)
                }
                DispatchQueue.main.asyncAfter(deadline: .now()+0.2, execute: {
                    self.updateDownloadStatus?( url, .paused)
                    if self.downLoadMode == .concurrent {
                        print("Ending Task - \(urlString)")
                        self.csemaphore.signal()
                        self.addDownload()
                    } else {
                        print("Ending Task - \(urlString)")
                        self.semaphore.signal()
                        self.addDownload()
                    }
                })
            }
        }
        guard let task = downloadTasks[urlString] else { return }
        task.suspend()
        self.downloadTasks.removeValue(forKey: urlString)
        // Save the current byte offset
        resumedByteOffsets[urlString] = task.countOfBytesReceived
        print("Paused downloading: \(url.lastPathComponent) at byte offset: \(resumedByteOffsets[urlString] ?? 0)")
        task.cancel(byProducingResumeData: { (resumeData) in
            // You have to set download data with resume data
            if let resumeData = resumeData {
                Task { @MainActor in
                    print("Captured resume data for \(urlString)")
                    self.resumedData[urlString] = resumeData
                    self.saveDownloadState()
                }
            }
        })
        
    }
    
//    // Cancel all downloads
//    func pauseAllDownloads() {
//        for task in downloadTasks.values {
//            task.cancel()
//        }
//        downloadTasks.removeAll()
//        resumedByteOffsets.removeAll()
//        totalByteOffsets.removeAll()
//
//        downloadURLs.removeAll()
//        print("All downloads canceled.")
//        clearDownloadState()
//    }
//
    
    // Resume a paused download
    func resumeDownload(from url: URL) {
        let urlString = url.absoluteString
        if let urlindex = self.queueList.firstIndex(where: { $0.fileUrl?.absoluteString == urlString }) {
            self.queueList[urlindex].downloadstate = .resumed
            let new = self.queueList[urlindex]
            self.queueList.remove(at: urlindex)
            if let lastindex = self.queueList.lastIndex(where: { $0.downloadstate == .waiting || $0.downloadstate == .resumed || $0.downloadstate == .downloading}) {
                self.queueList.insert(new, at: lastindex+1)
            } else {
                self.queueList.insert(new, at: 0)
            }
            self.updateDownloadStatus?( url, .resumed)
        }
        
        
        if self.downLoadMode == .concurrent {
            self.addDownload()
        } else {
            self.addDownload()
        }/* else {
          
          var request = URLRequest(url: url)
          request.setValue("bytes=\(resumedByteOffset)-", forHTTPHeaderField: "Range") // Specify range for the resumed download
          
          let resumedTask = urlSession.downloadTask(with: request)
          resumedTask.resume()
          
          // Replace the paused task with the resumed task
          downloadTasks[urlString] = resumedTask
          }*/
    }
    
    // Cancel a download
    func cancelDownload(from url: URL) {
        let urlString = url.absoluteString
        if let urlindex = self.queueList.firstIndex(where: { $0.fileUrl?.absoluteString == urlString }) {
            self.queueList[urlindex].downloadstate = .canceled
            self.queueList.remove(at: urlindex)
            self.updateDownloadStatus?( url, .canceled)
        }
        if let urlindex = self.downloadList.firstIndex(where: { $0.fileUrl?.absoluteString == urlString }) {
            self.deleteFileOrFolder(atPath: self.downloadList[urlindex].fileSavePath ?? "", url: url)
            self.downloadList.remove(at: urlindex)
        }
        resumedData.removeValue(forKey: urlString)
        guard let task = downloadTasks[urlString] else { return }
        task.cancel()
        downloadTasks.removeValue(forKey: urlString)
        resumedByteOffsets.removeValue(forKey: urlString)
        totalByteOffsets.removeValue(forKey: urlString)
        downloadURLs.removeValue(forKey: urlString)
        unzipStatus.removeValue(forKey: urlString)
        resumedData.removeValue(forKey: urlString)
        print("Canceled downloading: \(url.lastPathComponent)")
        saveDownloadState()
    }
    
    // Cancel all downloads
    func cancelAllDownloads() {
        self.downloadList.removeAll()
        self.queueList.removeAll()
        for task in downloadTasks.values {
            task.cancel()
        }
        downloadTasks.removeAll()
        resumedByteOffsets.removeAll()
        totalByteOffsets.removeAll()
        downloadURLs.removeAll()
        unzipStatus.removeAll()
        resumedData.removeAll()
        print("All downloads canceled.")
        clearDownloadState()
    }
    
    // Save download state to UserDefaults
    func saveDownloadState() {
        var downloadState: [[String: Any]] = []
        
        for (urlString, offset) in resumedByteOffsets {
            if let url = downloadURLs[urlString],let totaloffset = totalByteOffsets[urlString],let unzipStatus = unzipStatus[urlString] {
                if let urlindex = self.downloadList.firstIndex(where: { $0.fileUrl?.absoluteString == urlString }) {
                    if let resumeData = resumedData[urlString] {
                        let state: [String: Any] = [
                            "url": url.absoluteString,
                            "offset": offset,
                            "totaloffset": totaloffset,
                            "unzipStatus": unzipStatus,
                            "path":  self.downloadList[urlindex].fileSavePath ?? "",
                            "resumeData": resumeData
                        ]
                        downloadState.append(state)
                    } else {
                        let state: [String: Any] = [
                            "url": url.absoluteString,
                            "offset": offset,
                            "totaloffset": totaloffset,
                            "unzipStatus": unzipStatus,
                            "path":  self.downloadList[urlindex].fileSavePath ?? ""
                        ]
                        downloadState.append(state)
                    }
                    
                    
                }
            }
        }
        
        UserDefaults.standard.set(downloadState, forKey: "downloadState")
    }
    
    // Load download state from UserDefaults
    private func loadDownloadState() {
        if let downloadState = UserDefaults.standard.array(forKey: "downloadState") as? [[String: Any]] {
            for state in downloadState {
                if let urlString = state["url"] as? String, let url = URL(string: urlString), let offset = state["offset"] as? Int64, let totaloffset = state["totaloffset"] as? Int64, let unzipStatus = state["unzipStatus"] as? Bool {
                    self.downloadURLs[urlString] = url
                    self.resumedByteOffsets[urlString] = offset
                    self.totalByteOffsets[urlString] = totaloffset
                    if let resumeData = state["resumeData"] as? Data {
                        self.resumedData[urlString] = resumeData
                    }
                    self.unzipStatus[urlString] = unzipStatus
                    // Attempt to resume the download
                }
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now()+0.4, execute: {
                if self.needAutoDownload {
                    for state in downloadState {
                        if let urlString = state["url"] as? String, let url = URL(string: urlString), let offset = state["offset"] as? Int64,let path = state["path"] as? String, let totaloffset = state["totaloffset"] as? Int64, let unzipStatus = state["unzipStatus"] as? Bool {
                            self.downloadURLs[urlString] = url
                            self.resumedByteOffsets[urlString] = offset
                            self.totalByteOffsets[urlString] = totaloffset
                            if self.downloadList.first(where: { $0.fileUrl?.absoluteString == urlString }) == nil {
                                self.downloadList.append(MyDownload(fileSavePath: path,fileUrl: url,needUnzip: unzipStatus))
                            }
                            if let resumeData = state["resumeData"] as? Data {
                                self.resumedData[urlString] = resumeData
                            }
                            self.unzipStatus[urlString] = unzipStatus
                            self.resumeDownload(from: url)  // Attempt to resume the download
                        }
                    }
                }
            })
        }
    }
    
    // Clear saved download state
    private func clearDownloadState() {
        UserDefaults.standard.removeObject(forKey: "downloadState")
    }
    
    // Delegate method to track download progress
    nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            let urlString = downloadTask.originalRequest?.url?.absoluteString ?? ""
            resumedByteOffsets[urlString] = downloadTask.countOfBytesReceived
            totalByteOffsets[urlString] = totalBytesExpectedToWrite
            saveDownloadState()
//            print("Downloading \(downloadTask.originalRequest?.url?.lastPathComponent ?? "file")")
//            print("Download Progress: ", "\(Int(progress * 100))%", totalBytesWritten.formatBytes(), totalBytesExpectedToWrite.formatBytes())
            let currentFileSizeString = totalBytesWritten.formatBytes();
            let totalFileSizeString = totalBytesExpectedToWrite.formatBytes();
            self.updateProgress?(downloadTask.originalRequest?.url, Double(Int(progress * 100)), currentFileSizeString, totalFileSizeString)
        }
    }

    // Delegate method to handle download completion
    nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let urlString = downloadTask.originalRequest?.url?.absoluteString ?? ""
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var destinationURL = documentsDirectory
        do {
            destinationURL.appendPathComponent((downloadTask.originalRequest?.url!.lastPathComponent)!)
            let source = destinationURL
            // Move the downloaded file to the Documents directory
            try FileManager.default.moveItem(at: location, to: source)
            print("File moved to: \(source)")
            Task { @MainActor in
                self.unzipMethod(urlString: urlString, source: source, url: downloadTask.originalRequest!.url!)
            }
        } catch {
            print("Error moving file: \(error)")
            Task { @MainActor in
                if self.downLoadMode == .concurrent {
                    print("Ending Task - \(urlString)")
                    self.csemaphore.signal()
                    self.addDownload()
                } else {
                    print("Ending Task - \(urlString)")
                    self.semaphore.signal()
                    self.addDownload()
                }
            }
        }
        
    }
    
    // Handle download errors
    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            let urlString = task.originalRequest?.url?.absoluteString ?? ""
            Task { @MainActor in
                if self.resumedData[urlString] == nil {
                    print("Download failed for \(task.originalRequest?.url?.lastPathComponent ?? "file"): \(error.localizedDescription)")
                    if self.downLoadMode == .concurrent {
                        print("Ending Task - \(urlString)")
                        self.csemaphore.signal()
                        self.addDownload()
                    } else {
                        print("Ending Task - \(urlString)")
                        self.semaphore.signal()
                        self.addDownload()
                    }
                    if let downloadTask = task as? URLSessionDownloadTask {
                        self.updateDownloadfailed?(downloadTask.originalRequest?.url)
                    }
                }
            }
            
        }
    }

    // Save partial data for resumption in case the app gets terminated or interrupted
    nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        print("Resumed download at offset: \(fileOffset), expected total bytes: \(expectedTotalBytes)")
    }

    func checkServerSupportForRange(url: URL, completion: @escaping @Sendable (Bool) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let task = urlSession.dataTask(with: request) { data, response, error in
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 206 {
                completion(true)  // Server supports range
            } else {
                completion(false) // Server does not support range
            }
        }
        task.resume()
    }
    
    @MainActor func unzipMethod(urlString:String,source:URL,url:URL) {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var destinationURL = documentsDirectory
        
        if let urlindex = self.queueList.firstIndex(where: { $0.fileUrl?.absoluteString == urlString }) {
            destinationURL.appendPathComponent(self.queueList[urlindex].fileSavePath ?? "")
            downloadTasks.removeValue(forKey: urlString)
            resumedByteOffsets.removeValue(forKey: urlString)
            totalByteOffsets.removeValue(forKey: urlString)
            downloadURLs.removeValue(forKey: urlString)
            unzipStatus.removeValue(forKey: urlString)

            let needUnzip = self.queueList[urlindex].needUnzip
            let filesize = self.getFileSize(atPath: source.path)
            if needUnzip {
                self.queueList.remove(at: urlindex)
                if let urlindex = self.downloadList.firstIndex(where: { $0.fileUrl?.absoluteString == urlString }) {
                    self.downloadList.remove(at: urlindex)
                }
                self.unZipFile(source: source.path, dest: destinationURL.path) { status in
                    if self.downLoadMode == .concurrent {
                        print("Ending Task - \(urlString)")
                        self.csemaphore.signal()
                        self.addDownload()
                    } else {
                        print("Ending Task - \(urlString)")
                        self.semaphore.signal()
                        self.addDownload()
                    }
                    if status {
                        if self.queueList.isEmpty {
                            self.clearDownloadState()
                            self.updateSingleDownloaded?(url, true,filesize.formatBytes())
                        } else {
                            self.updateSingleDownloaded?(url, false, filesize.formatBytes())
                        }
                    }
                }
            } else {
                // Move the downloaded file to the Documents directory
                do {
                    if !FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true, attributes: nil)
                    }
                    
                    // Move the downloaded file to the Documents directory
                    destinationURL.appendPathComponent(url.lastPathComponent)
                    try FileManager.default.moveItem(at: source, to: destinationURL)
                    print("File moved to: \(destinationURL)")
                    Task {
                        if FileManager.default.fileExists(atPath: source.path) {
                            try! FileManager.default.removeItem(at: source)
                            print("Existing file deleted at destination: \(source.path)")
                        }
                    }
                } catch {
                    print("Error moving file: \(error)")
                }
                if self.downLoadMode == .concurrent {
                    print("Ending Task - \(urlString)")
                    self.csemaphore.signal()
                    self.addDownload()
                } else {
                    print("Ending Task - \(urlString)")
                    self.semaphore.signal()
                    self.addDownload()
                }
                self.queueList.remove(at: urlindex)
                if let urlindex = self.downloadList.firstIndex(where: { $0.fileUrl?.absoluteString == urlString }) {
                    self.downloadList.remove(at: urlindex)
                }
                if self.downloadList.isEmpty {
                    self.clearDownloadState()
                    self.updateSingleDownloaded?(url, true,filesize.formatBytes())
                } else {
                    self.updateSingleDownloaded?(url, false, filesize.formatBytes())
                }
            }
        } else {
            let filesize = self.getFileSize(atPath: source.path)
            downloadTasks.removeValue(forKey: urlString)
            resumedByteOffsets.removeValue(forKey: urlString)
            totalByteOffsets.removeValue(forKey: urlString)
            downloadURLs.removeValue(forKey: urlString)
            unzipStatus.removeValue(forKey: urlString)
            downloadList.removeAll()
            queueList.removeAll()
            if self.downLoadMode == .concurrent {
                print("Ending Task - \(urlString)")
                self.csemaphore.signal()
                self.addDownload()
            } else {
                print("Ending Task - \(urlString)")
                self.semaphore.signal()
                self.addDownload()
            }
            if let urlindex = self.queueList.firstIndex(where: { $0.fileUrl?.absoluteString == urlString }) {
                self.queueList[urlindex].downloadstate = .downloaded
            }
            if self.queueList.isEmpty {
                self.clearDownloadState()
                self.updateSingleDownloaded?(url, true,filesize.formatBytes())
            } else {
                self.updateSingleDownloaded?(url, false, filesize.formatBytes())
            }
        }
    }
    
    // Helper to get the destination URL where the file should be saved
    private func getDestinationURL(for task: URLSessionDownloadTask) -> URL {
        guard let url = task.originalRequest?.url else {
            fatalError("URL not found")
        }
        
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destinationURL = documentsDirectory.appendingPathComponent(url.lastPathComponent)
        
        return destinationURL
    }
    
    func deleteFileOrFolder(atPath path:String,url:URL) {
        let urlString = url.absoluteString
        var documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let urlindex = self.downloadList.firstIndex(where: { $0.fileUrl?.absoluteString == urlString }) {
            documentsDirectory.appendPathComponent(self.downloadList[urlindex].fileSavePath ?? "")
            let needUnzip = self.downloadList[urlindex].needUnzip
            if needUnzip {
                if FileManager.default.fileExists(atPath: documentsDirectory.path) {
                    try! FileManager.default.removeItem(at: documentsDirectory)
                    print("Existing file deleted at destination: \(documentsDirectory.path)")
                }
            } else {
                documentsDirectory.appendPathComponent(url.lastPathComponent)
                if FileManager.default.fileExists(atPath: documentsDirectory.path) {
                    try! FileManager.default.removeItem(at: documentsDirectory)
                    print("Existing file deleted at destination: \(documentsDirectory.path)")
                }
            }
        }
    }
    func getExistFileSize(atPath path: String) -> (Bool,String) {
        let file = self.checkIfFileOrDirectory(atPath: path)
        switch file {
        case "directory":
            let file = self.checkfile(name: path)
            if file.status {
                let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let url = documentsDirectory.appendingPathComponent(path)
                let fileSize = self.directorySize(atPath: url.path)
                return (true,fileSize.humanReadableSize())
            }
            return (false,"")

            
        case "file":
            let file = self.checkfile(name: path)
            if file.status {
                let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let url = documentsDirectory.appendingPathComponent(path)
                let fileSize = self.getFileSize(atPath: url.path)
                return (true,fileSize.formatBytes())
            }
            return (false,"")

        default:
            return (false,"")
        }
    }

    func getFileSize(atPath path: String) -> Int64 {
        let fileManager = FileManager.default
        do {
            // Get attributes of the file at the given path
            let attributes = try fileManager.attributesOfItem(atPath: path)
            // Return the size of the file
            if let fileSize = attributes[.size] as? UInt64 {
                return Int64(fileSize)
            }
        } catch {
            print("Error getting file size: \(error)")
        }
        return 0
    }

    
    func unZipFile(source:String,dest:String, completion:@escaping(_ status:Bool) -> Void) -> Void{
        SSZipArchive.unzipFile(atPath: source, toDestination: dest, progressHandler: {
            (entry, zipInfo, readByte, totalByte) -> Void in
        }, completionHandler: { (path, success, error) -> Void in
            if success {
                //SUCCESSFUL!!
                print("Unziped scussesful")
                let sourceP = URL(fileURLWithPath: source)
                if FileManager.default.fileExists(atPath: source) {
                    try! FileManager.default.removeItem(at: sourceP)
                    print("Existing file deleted at destination: \(sourceP.path)")
                }
                completion(true);
            } else {
                print("Problem to unzip file :\(String(describing: error))")
                completion(false);
            }
        })
    }
    
    func checkIfFileOrDirectory(atPath path: String) -> String {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documentsDirectory.appendingPathComponent(path)

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        // Check if the path exists and determine if it's a directory or a file
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                print("\(path) is a directory.")
                return "directory"
            } else {
                print("\(path) is a file.")
                return "file"
            }
        } else {
            print("The path does not exist.")
            return ""
        }
    }
    
    
    func directorySize(atPath path: String) -> UInt64 {
        let fileManager = FileManager.default
        var folderSize: UInt64 = 0
        do {
            // Get the contents of the directory
            let directoryContents = try fileManager.contentsOfDirectory(atPath: path)
            
            for file in directoryContents {
                let filePath = (path as NSString).appendingPathComponent(file)
                var isDirectory: ObjCBool = false
                // Check if it's a directory
                if fileManager.fileExists(atPath: filePath, isDirectory: &isDirectory) {
                    if isDirectory.boolValue {
                        // If it's a directory, recursively calculate the folder size
                        folderSize += self.directorySize(atPath: filePath)
                    } else {
                        // If it's a file, get its size
                        let attributes = try fileManager.attributesOfItem(atPath: filePath)
                        if let fileSize = attributes[.size] as? UInt64 {
                            folderSize += fileSize
                        }
                    }
                }
            }
        } catch {
            print("Error reading contents of directory: \(error)")
        }
        
        return folderSize
    }
}

extension Int64 {
    func formatBytes() -> String {
        let units = ["Bytes", "KB", "MB", "GB", "TB", "PB"]
        var size = Double(self)
        var unitIndex = 0
        
        while size >= 1024 && unitIndex < units.count - 1 {
            size /= 1024
            unitIndex += 1
        }
        return String(format: "%.2f %@", size, units[unitIndex])
    }
}

extension UInt64 {
    func humanReadableSize() -> String {
        let kb = UInt64(1024)
        let mb = kb * 1024
        let gb = mb * 1024
        let tb = gb * 1024

        if self < kb {
            return "\(self) bytes"
        } else if self < mb {
            return String(format: "%.2f KB", Double(self) / Double(kb))
        } else if self < gb {
            return String(format: "%.2f MB", Double(self) / Double(mb))
        } else if self < tb {
            return String(format: "%.2f GB", Double(self) / Double(gb))
        } else {
            return String(format: "%.2f TB", Double(self) / Double(tb))
        }
    }
}

extension URL{
    //MARK: - Check Existing Path
    func checkMyFileExist() -> Bool {
        print("Output ==== >> \(self.path)")
        let path = self.path
        if (FileManager.default.fileExists(atPath: path))   {
            print("FILE AVAILABLE")
            return true
        }else        {
            print("FILE NOT AVAILABLE")
            return false;
        }
    }
    
    func checkFileExist() -> Bool {
        let documentDirUrl = try! FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let path = self.path
        let fileURL = documentDirUrl.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return true;
        }
        return false;
    }

}
