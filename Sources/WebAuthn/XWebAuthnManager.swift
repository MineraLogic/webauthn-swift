//===----------------------------------------------------------------------===//
// This is a substantially streamlined version of the webauthn-swift 
// WebAuthnMananger structure.  Here the API is reduced to just two
// functions:
//
// * performRegistration - to establish new webauthn credentials
// * preformAuthentication - to verify an identity claim against
//                           existing credentials.
//
// NOTE: Here the API user is responsible for generating the challenge
// bytes tracking the relyingParty information.
//
// Original license information follows.
//
//===----------------------------------------------------------------------===//
//
// This source file is part of the WebAuthn Swift open source project
//
// Copyright (c) 2022 the WebAuthn Swift project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of WebAuthn Swift project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation

public struct XWebAuthnContext {
    /// The unique identifier for these credentials
    public let id: Data
    
    /// The nonce (random bytes) specific to this ceremony
    public let challenge: Data

    /// The entity that is performing the ceremony
    public let relyingPartyID: String
    
    /// The URL associated with the relying party
    public let relyingPartyOrigin: String
    
    public init(id: Data, challenge: Data, relyingPartyID: String, relyingPartyOrigin: String) {
        self.id = id
        self.challenge = challenge
        self.relyingPartyID = relyingPartyID
        self.relyingPartyOrigin = relyingPartyOrigin
    }
}


/// Main entrypoint for WebAuthn registration and authentication ceremonies.
///
public struct XWebAuthnManager {
    /// Take response from authenticator and client and verify credential against the user's credentials and
    /// session data.
    ///
    /// - Parameters:
    ///   - challenge: The challenge passed to the authenticator within the preceding registration options.
    ///   - credentialCreationData: The value returned from `navigator.credentials.create()`
    ///   - requireUserVerification: Whether or not to require that the authenticator verified the user.
    ///   - supportedPublicKeyAlgorithms: A list of public key algorithms the Relying Party chooses to restrict
    ///     support to. Defaults to all supported algorithms.
    ///   - pemRootCertificatesByFormat: A list of root certificates used for attestation verification.
    ///     If attestation verification is not required (default behavior) this parameter does nothing.
    ///   - confirmCredentialIDNotRegisteredYet: For a successful registration ceremony we need to verify that the
    ///     `credentialId`, generated by the authenticator, is not yet registered for any user. This is a good place to
    ///     handle that.
    /// - Returns:  A new `Credential` with information about the authenticator and registration
    public static func validateRegistration(
        context: XWebAuthnContext,
        clientDataJSON:Data,
        attestationObject:Data,
        requireUserVerification: Bool = false,
        supportedPublicKeyAlgorithms: [PublicKeyCredentialParameters] = .supported,
        pemRootCertificatesByFormat: [AttestationFormat: [Data]] = [:]
    ) async throws -> Credential {
        let idBytes = [UInt8](context.id)
        let jsonDataBytes = [UInt8](clientDataJSON)
        let attestationBytes = [UInt8](attestationObject)
        let challengeBytes = [UInt8](context.challenge)
        
        let credentialCreationData = RegistrationCredential(id: "", type: "CredentialType/publicKey", rawID: idBytes, attestationResponse: AuthenticatorAttestationResponse(clientDataJSON: jsonDataBytes, attestationObject: attestationBytes))
        let parsedData = try ParsedCredentialCreationResponse(from: credentialCreationData)
        let attestedCredentialData = try await parsedData.verify(
            storedChallenge: challengeBytes,
            verifyUser: requireUserVerification,
            relyingPartyID: context.relyingPartyID,
            relyingPartyOrigin: context.relyingPartyOrigin,
            supportedPublicKeyAlgorithms: supportedPublicKeyAlgorithms,
            pemRootCertificatesByFormat: pemRootCertificatesByFormat
        )

        // TODO: Step 18. -> Verify client extensions

        // JC: This is handled outside of webauthn-swift
        // Step 24.
        // guard try await confirmCredentialIDNotRegisteredYet(parsedData.id.asString()) else {
        //    throw WebAuthnError.credentialIDAlreadyExists
        // }

        // Step 25.
        return Credential(
            type: parsedData.type,
            id: parsedData.id.urlDecoded.asString(),
            publicKey: attestedCredentialData.publicKey,
            signCount: parsedData.response.attestationObject.authenticatorData.counter,
            backupEligible: parsedData.response.attestationObject.authenticatorData.flags.isBackupEligible,
            isBackedUp: parsedData.response.attestationObject.authenticatorData.flags.isCurrentlyBackedUp,
            attestationObject: parsedData.response.attestationObject,
            attestationClientDataJSON: parsedData.response.clientData
        )
    }

    /// Verify a response from navigator.credentials.get()
    ///
    /// - Parameters:
    ///   - clientDataJSON:
    ///   - id: credential ID associated with the request
    ///   - credential: The value returned from `navigator.credentials.get()`.
    ///   - expectedChallenge: The challenge passed to the authenticator within the preceding authentication options.
    ///   - credentialPublicKey: The public key for the credential's ID as provided in a preceding authenticator
    ///     registration ceremony.
    ///   - credentialCurrentSignCount: The current known number of times the authenticator was used.
    ///   - requireUserVerification: Whether or not to require that the authenticator verified the user.
    /// - Returns: Information about the authenticator
    public static func validateAuthentication(
        id: Data,
        credential: AuthenticationCredential,
        expectedChallenge: Data,
        relyingPartyID:String,
        relyingPartyOrigin:String,
        credentialPublicKey: Data,
        credentialCurrentSignCount: UInt32,
        requireUserVerification: Bool = false
    ) throws -> VerifiedAuthentication {


        public struct AuthenticationCredential {
            /// The credential ID of the newly created credential.
            public let id: URLEncodedBase64

            /// The raw credential ID of the newly created credential.
            public let rawID: [UInt8]

            /// The attestation response from the authenticator.
            public let response: AuthenticatorAssertionResponse

            /// Reports the authenticator attachment modality in effect at the time the navigator.credentials.create() or
            /// navigator.credentials.get() methods successfully complete
            public let authenticatorAttachment: AuthenticatorAttachment?

            /// Value will always be ``CredentialType/publicKey`` (for now)
            public let type: CredentialType
        }

        public struct AuthenticatorAssertionResponse {
            /// Representation of what we passed to `navigator.credentials.get()`
            ///
            /// When decoding using `Decodable`, this is decoded from base64url to bytes.
            public let clientDataJSON: [UInt8]

            /// Contains the authenticator data returned by the authenticator.
            ///
            /// When decoding using `Decodable`, this is decoded from base64url to bytes.
            public let authenticatorData: [UInt8]

            /// Contains the raw signature returned from the authenticator
            ///
            /// When decoding using `Decodable`, this is decoded from base64url to bytes.
            public let signature: [UInt8]

            /// Contains the user handle returned from the authenticator, or null if the authenticator did not return
            /// a user handle. Used by to give scope to credentials.
            ///
            /// When decoding using `Decodable`, this is decoded from base64url to bytes.
            public let userHandle: [UInt8]?

            /// Contains an attestation object, if the authenticator supports attestation in assertions.
            /// The attestation object, if present, includes an attestation statement. Unlike the attestationObject
            /// in an AuthenticatorAttestationResponse, it does not contain an authData key because the authenticator
            /// data is provided directly in an AuthenticatorAssertionResponse structure.
            ///
            /// When decoding using `Decodable`, this is decoded from base64url to bytes.
            public let attestationObject: [UInt8]?
        }

        
        
        
        guard credential.type == .publicKey
        else { throw WebAuthnError.invalidAssertionCredentialType }

        let expectedChallengeBytes = [UInt8](expectedChallenge)
        let publicKeyBytes = [UInt8](credentialPublicKey)
        
        let parsedAssertion = try ParsedAuthenticatorAssertionResponse(from: credential.response)
        try parsedAssertion.verify(
            expectedChallenge: expectedChallengeBytes,
            relyingPartyOrigin: relyingPartyOrigin,
            relyingPartyID: relyingPartyID,
            requireUserVerification: requireUserVerification,
            credentialPublicKey: publicKeyBytes,
            credentialCurrentSignCount: credentialCurrentSignCount
        )

        return VerifiedAuthentication(
            credentialID: credential.id,
            newSignCount: parsedAssertion.authenticatorData.counter,
            credentialDeviceType: parsedAssertion.authenticatorData.flags.deviceType,
            credentialBackedUp: parsedAssertion.authenticatorData.flags.isCurrentlyBackedUp
        )
    }
}
