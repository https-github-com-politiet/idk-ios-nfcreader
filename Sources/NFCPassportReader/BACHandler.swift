//
//  BACHandler.swift
//  NFCTest
//
//  Created by Andy Qua on 07/06/2019.
//  Copyright © 2019 Andy Qua. All rights reserved.
//

import Foundation
import FirebaseCrashlytics

#if !os(macOS)
import CoreNFC

@available(iOS 13, *)
public class BACHandler {
    let KENC : [UInt8] = [0,0,0,1]
    let KMAC : [UInt8] = [0,0,0,2]
    
    public var ksenc : [UInt8] = []
    public var ksmac : [UInt8] = []

    var rnd_icc : [UInt8] = []
    var rnd_ifd : [UInt8] = []
    public var kifd : [UInt8] = []
    
    var tagReader : TagReader?
    
    public init() {
        // For testing only
    }
    
    public init(tagReader: TagReader) {
        self.tagReader = tagReader
    }

    public func performBACAndGetSessionKeys( mrzKey : String, completed: @escaping (_ error : NFCPassportReaderError?)->() ) {
        guard let tagReader = self.tagReader else {
            completed( NFCPassportReaderError.NoConnectedTag)
            return
        }
        
        Log.debug("BACHandler - deriving Document Basic Access Keys")
        do {
            _ = try self.deriveDocumentBasicAccessKeys(mrz: mrzKey)
        } catch {
            Log.error("Error deriving Document Basic Access Keys", error)
            completed( NFCPassportReaderError.InvalidDataPassed("Unable to derive BAC Keys - \(error.localizedDescription)") )
            return

        }
        
        // Make sure we clear secure messaging (could happen if we read an invalid DG or we hit a secure error
        tagReader.secureMessaging = nil
        
        // get Challenge
        Log.debug("BACHandler - Getting initial challenge")
        tagReader.getChallenge() { [unowned self] (response, error) in
            
            guard let response = response else {
                Log.error("BACHandler - error getting initial challenge - \(error?.localizedDescription ?? "")" )
                completed( error )
                return
            }
            Log.debug( "BACHandler initial challenge data - \(response.data)" )
            
            Log.debug( "BACHandler - Doing mutual authentication" )
            let cmd_data = self.authentication(rnd_icc: [UInt8](response.data))
            tagReader.doMutualAuthentication(cmdData: Data(cmd_data)) { [unowned self] (response, error) in
                guard let response = response else {
                    Log.error("BACHandler - error doing mutual authentication - \(error?.localizedDescription ?? "")" )
                    completed( error )
                    return
                }
                Log.debug( "BACHandler mutual authentication data - \(response.data)" )
                
                do {
                    let (KSenc, KSmac, ssc) = try self.sessionKeys(data: [UInt8](response.data))
                    tagReader.secureMessaging = SecureMessaging(ksenc: KSenc, ksmac: KSmac, ssc: ssc)
                    Log.debug( "BACHandler - complete" )
                    completed( nil)
                } catch {
                    Log.error("Unable to derive BAC keys", error)
                    completed( NFCPassportReaderError.InvalidDataPassed("Unable to derive BAC Keys - \(error.localizedDescription)") )
                }
            }
        }
    }


    func deriveDocumentBasicAccessKeys(mrz: String) throws -> ([UInt8], [UInt8]) {
        let kseed = generateInitialKseed(kmrz:mrz)
    
        Log.debug("Calculate the Basic Access Keys (Kenc and Kmac) using TR-SAC 1.01, 4.2")
        let smskg = SecureMessagingSessionKeyGenerator()
        self.ksenc = try smskg.deriveKey(keySeed: kseed, mode: .ENC_MODE)
        self.ksmac = try smskg.deriveKey(keySeed: kseed, mode: .MAC_MODE)
                
        return (ksenc, ksmac)
    }
    
    ///
    /// Calculate the kseed from the kmrz:
    /// - Calculate a SHA-1 hash of the kmrz
    /// - Take the most significant 16 bytes to form the Kseed.
    /// @param kmrz: The MRZ information
    /// @type kmrz: a string
    /// @return: a 16 bytes string
    ///
    /// - Parameter kmrz: mrz key
    /// - Returns: first 16 bytes of the mrz SHA1 hash
    ///
    func generateInitialKseed(kmrz : String ) -> [UInt8] {
        
        Log.debug("Calculate the SHA-1 hash of MRZ_information")
        Log.debug("\tMRZ KEY - \(kmrz)")
        let hash = calcSHA1Hash( [UInt8](kmrz.data(using:.utf8)!) )
        
        Log.debug("\tsha1(MRZ_information): \(binToHexRep(hash))")
        
        let subHash = Array(hash[0..<16])
        Log.debug("Take the most significant 16 bytes to form the Kseed")
        Log.debug("\tKseed: \(binToHexRep(subHash))" )
        
        return Array(subHash)
    }
    
    
    /// Construct the command data for the mutual authentication.
    /// - Request an 8 byte random number from the MRTD's chip (rnd.icc)
    /// - Generate an 8 byte random (rnd.ifd) and a 16 byte random (kifd)
    /// - Concatenate rnd.ifd, rnd.icc and kifd (s = rnd.ifd + rnd.icc + kifd)
    /// - Encrypt it with TDES and the Kenc key (eifd = TDES(s, Kenc))
    /// - Compute the MAC over eifd with TDES and the Kmax key (mifd = mac(pad(eifd))
    /// - Construct the APDU data for the mutualAuthenticate command (cmd_data = eifd + mifd)
    ///
    /// @param rnd_icc: The challenge received from the ICC.
    /// @type rnd_icc: A 8 bytes binary string
    /// @return: The APDU binary data for the mutual authenticate command
    func authentication( rnd_icc : [UInt8]) -> [UInt8] {
        self.rnd_icc = rnd_icc
        
        Log.debug("Request an 8 byte random number from the MRTD's chip")
        Log.debug("\tRND.ICC: \(binToHexRep(self.rnd_icc))")
        
        self.rnd_icc = rnd_icc

        let rnd_ifd = generateRandomUInt8Array(8)
        let kifd = generateRandomUInt8Array(16)
        
        Log.debug("Generate an 8 byte random and a 16 byte random")
        Log.debug("\tRND.IFD: \(binToHexRep(rnd_ifd))" )
        Log.debug("\tRND.Kifd: \(binToHexRep(kifd))")
        
        let s = rnd_ifd + rnd_icc + kifd
        
        Log.debug("Concatenate RND.IFD, RND.ICC and Kifd")
        Log.debug("\tS: \(binToHexRep(s))")
        
        let iv : [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0]
        let eifd = tripleDESEncrypt(key: ksenc,message: s, iv: iv)
        
        Log.debug("Encrypt S with TDES key Kenc as calculated in Appendix 5.2")
        Log.debug("\tEifd: \(binToHexRep(eifd))")
        
        let mifd = mac(algoName: .DES, key: ksmac, msg: pad(eifd, blockSize:8))

        Log.debug("Compute MAC over eifd with TDES key Kmac as calculated in-Appendix 5.2")
        Log.debug("\tMifd: \(binToHexRep(mifd))")
        // Construct APDU
        
        let cmd_data = eifd + mifd
        Log.debug("Construct command data for MUTUAL AUTHENTICATE")
        Log.debug("\tcmd_data: \(binToHexRep(cmd_data))")
        
        self.rnd_ifd = rnd_ifd
        self.kifd = kifd

        return cmd_data
    }
    
    /// Calculate the session keys (KSenc, KSmac) and the SSC from the data
    /// received by the mutual authenticate command.
    
    /// @param data: the data received from the mutual authenticate command send to the chip.
    /// @type data: a binary string
    /// @return: A set of two 16 bytes keys (KSenc, KSmac) and the SSC
    public func sessionKeys(data : [UInt8] ) throws -> ([UInt8], [UInt8], [UInt8])  {
        Log.debug("Decrypt and verify received data and compare received RND.IFD with generated RND.IFD \(binToHexRep(self.ksmac))" )
        
        let response = tripleDESDecrypt(key: self.ksenc, message: [UInt8](data[0..<32]), iv: [0,0,0,0,0,0,0,0] )

        let response_kicc = [UInt8](response[16..<32])
        let response_kifd = [UInt8](response[8..<16])
        
        guard response_kifd == self.rnd_ifd else {
            Crashlytics.crashlytics().setCustomValue("response_kifd doesn't match rnd_ifd", forKey: FirebaseCustomKeys.errorInfo)
            throw NFCPassportReaderError.InvalidResponse
        }
        
        let Kseed = xor(self.kifd, response_kicc)
        Log.debug("Calculate XOR of Kifd and Kicc")
        Log.debug("\tKseed: \(binToHexRep(Kseed))" )
        
        let smskg = SecureMessagingSessionKeyGenerator()
        let KSenc = try smskg.deriveKey(keySeed: Kseed, mode: .ENC_MODE)
        let KSmac = try smskg.deriveKey(keySeed: Kseed, mode: .MAC_MODE)

//        let KSenc = self.keyDerivation(kseed: Kseed,c: KENC)
//        let KSmac = self.keyDerivation(kseed: Kseed,c: KMAC)
        
        Log.debug("Calculate Session Keys (KSenc and KSmac) using Appendix 5.1")
        Log.debug("\tKSenc: \(binToHexRep(KSenc))" )
        Log.debug("\tKSmac: \(binToHexRep(KSmac))" )
        
        
        let ssc = [UInt8](self.rnd_icc.suffix(4) + self.rnd_ifd.suffix(4))
        Log.debug("Calculate Send Sequence Counter")
        Log.debug("\tSSC: \(binToHexRep(ssc))" )
        return (KSenc, KSmac, ssc)
    }
    
}
#endif
