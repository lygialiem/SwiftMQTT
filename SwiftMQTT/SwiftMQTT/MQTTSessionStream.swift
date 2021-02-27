//
//  MQTTSessionStream.swift
//  SwiftMQTT
//
//  Created by Ankit Aggarwal on 12/11/15.
//  Copyright © 2015 Ankit. All rights reserved.
//

import Foundation

protocol MQTTSessionStreamDelegate: class {
    func mqttReady(_ ready: Bool, in stream: MQTTSessionStream)
    func mqttErrorOccurred(in stream: MQTTSessionStream, error: Error?)
    func mqttReceived(in stream: MQTTSessionStream, _ read: StreamReader)
}

class MQTTSessionStream: NSObject {
    
    private var currentRunLoop: RunLoop?
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var sessionQueue: DispatchQueue
    private weak var delegate: MQTTSessionStreamDelegate?
    private var session: URLSession? = nil
    private var streamTask: URLSessionStreamTask? = nil

    private var inputReady = false
    private var outputReady = false
    private var timeout: TimeInterval
    
    init(host: String, port: UInt16, ssl: Bool, timeout: TimeInterval, delegate: MQTTSessionStreamDelegate?) {
        self.timeout = timeout
        let queueLabel = host.components(separatedBy: ".").reversed().joined(separator: ".") + ".stream\(port)"
        self.sessionQueue = DispatchQueue(label: queueLabel, qos: .background, target: nil)
        self.delegate = delegate

        super.init()
        
        session = URLSession(configuration: URLSessionConfiguration.default, delegate: self, delegateQueue: nil)
        streamTask = session!.streamTask(withHostName: host, port: Int(port))
        if ssl {
            streamTask!.startSecureConnection()
        }
        streamTask!.captureStreams()
        streamTask!.resume()
        
    }
    
    deinit {
        delegate = nil
        guard let currentRunLoop = currentRunLoop else { return }
        inputStream?.close()
        inputStream?.remove(from: currentRunLoop, forMode: .default)
        outputStream?.close()
        outputStream?.remove(from: currentRunLoop, forMode: .default)
    }
    
    var write: StreamWriter? {
        if let outputStream = outputStream, outputReady {
            return outputStream.write
        }
        return nil
    }

    internal func connectTimeout() {
        if inputReady == false || outputReady == false {
            delegate?.mqttReady(false, in: self)
        }
    }
}

extension MQTTSessionStream: URLSessionStreamDelegate {
    
    func urlSession(_ session: URLSession, streamTask: URLSessionStreamTask, didBecome inputStream: InputStream, outputStream: OutputStream) {
      //setup the streams

        self.inputStream = inputStream
        self.inputStream!.delegate = self
        self.outputStream = outputStream
        self.outputStream!.delegate = self
        self.sessionQueue.async { [weak self] in
            guard let `self` = self else {
              return
            }
            self.currentRunLoop = RunLoop.current
            self.inputStream!.schedule(in: self.currentRunLoop!, forMode: RunLoop.Mode.default)
            self.outputStream!.schedule(in: self.currentRunLoop!, forMode: RunLoop.Mode.default)
            self.inputStream!.open()
            self.outputStream!.open()
            if self.timeout > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() +  self.timeout) {
                    self.connectTimeout()
                }
            }
            self.currentRunLoop!.run()

        }

    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

}

extension MQTTSessionStream: StreamDelegate {

    @objc internal func stream(_ aStream: Stream, handle eventCode: Stream.Event) {

        switch eventCode {

        case Stream.Event.openCompleted:
            let wasReady = inputReady && outputReady
            if aStream == inputStream {
                inputReady = true
            }
            else if aStream == outputStream {
                // output almost ready
            }
            if !wasReady && inputReady && outputReady {
                delegate?.mqttReady(true, in: self)
            }

        case Stream.Event.hasBytesAvailable:
            if aStream == inputStream {
                delegate?.mqttReceived(in: self, inputStream!.read)
            }

        case Stream.Event.errorOccurred:
            delegate?.mqttErrorOccurred(in: self, error: aStream.streamError)

        case Stream.Event.endEncountered:
            if aStream.streamError != nil {
                delegate?.mqttErrorOccurred(in: self, error: aStream.streamError)
            }

        case Stream.Event.hasSpaceAvailable:
            let wasReady = inputReady && outputReady
            if aStream == outputStream {
                outputReady = true
            }
            if !wasReady && inputReady && outputReady {
                delegate?.mqttReady(true, in: self)
            }

        default:
            break
        }
    }
}
