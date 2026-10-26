import Foundation
import Network
import Security

/// Headroom's own certificate authority, so the relay can read Claude Code's requests to
/// `api.anthropic.com`. Claude Code trusts it only through `NODE_EXTRA_CA_CERTS`; it is never added
/// to the system's trust settings. A name constraint limits it to `api.anthropic.com`, so even a leaked
/// key could not impersonate any other site.
enum LocalCA {
    static let host = "api.anthropic.com"
    // RSA throughout: LibreSSL writes EC keys with explicit curve parameters, which Claude Code's TLS
    // stack can't decode, and `SecPKCS12Import` with `kSecImportToMemoryOnly` crashes on them.
    static var caCert: URL { HeadroomPaths.relayDir.appendingPathComponent("ca-rsa.pem") }
    private static var caKey: URL { HeadroomPaths.relayDir.appendingPathComponent("ca-rsa.key") }
    private static var leafKey: URL { HeadroomPaths.relayDir.appendingPathComponent("leaf-rsa.key") }
    private static var leafCert: URL { HeadroomPaths.relayDir.appendingPathComponent("leaf-rsa.pem") }
    private static var leafP12: URL { HeadroomPaths.relayDir.appendingPathComponent("leaf-rsa.p12") }
    private static let p12Password = "headroom"   // the file itself is readable by the user only

    /// Creates the CA and a leaf for `api.anthropic.com` when missing or about to expire.
    static func ensure() throws {
        HeadroomPaths.ensure(HeadroomPaths.relayDir)
        let fm = FileManager.default
        if !fm.fileExists(atPath: caKey.path) || !fm.fileExists(atPath: caCert.path) || expiresSoon(caCert, days: 60) {
            try openssl(["req", "-x509", "-newkey", "rsa:3072", "-nodes",
                         "-keyout", caKey.path, "-out", caCert.path, "-days", "3650",
                         "-subj", "/CN=Headroom Local CA (api.anthropic.com only)",
                         "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
                         "-addext", "keyUsage=critical,keyCertSign,cRLSign",
                         "-addext", "nameConstraints=critical,permitted;DNS:\(host)"])
            try? fm.removeItem(at: leafP12)
        }
        if !fm.fileExists(atPath: leafP12.path) || expiresSoon(leafCert, days: 30) {
            let ext = HeadroomPaths.relayDir.appendingPathComponent("leaf.cnf")
            try """
            [ext]
            basicConstraints=critical,CA:FALSE
            keyUsage=critical,digitalSignature,keyEncipherment
            extendedKeyUsage=serverAuth
            subjectAltName=DNS:\(host)
            """.write(to: ext, atomically: true, encoding: .utf8)
            let csr = HeadroomPaths.relayDir.appendingPathComponent("leaf.csr")
            try openssl(["req", "-new", "-newkey", "rsa:2048", "-nodes",
                         "-keyout", leafKey.path, "-out", csr.path, "-subj", "/CN=\(host)"])
            try openssl(["x509", "-req", "-in", csr.path, "-CA", caCert.path, "-CAkey", caKey.path, "-CAcreateserial",
                         "-out", leafCert.path, "-days", "397", "-sha256", "-extfile", ext.path, "-extensions", "ext"])
            try openssl(["pkcs12", "-export", "-inkey", leafKey.path, "-in", leafCert.path, "-out", leafP12.path,
                         "-passout", "pass:\(p12Password)"])
            for url in [csr, ext] { try? fm.removeItem(at: url) }
        }
        for url in [caKey, leafKey, leafP12] { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: caCert.path)
    }

    /// The leaf certificate and key for the relay's TLS listener, kept in memory only.
    static func identity() throws -> sec_identity_t {
        let data = try Data(contentsOf: leafP12)
        let options: [String: Any] = [kSecImportExportPassphrase as String: p12Password,
                                      kSecImportToMemoryOnly as String: true]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let ref = first[kSecImportItemIdentity as String] else {
            throw ProviderError.message("Could not load the relay certificate (\(status)).")
        }
        guard let identity = sec_identity_create(ref as! SecIdentity) else {
            throw ProviderError.message("Could not use the relay certificate.")
        }
        return identity
    }

    private static func expiresSoon(_ cert: URL, days: Int) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = ["x509", "-checkend", String(days * 86400), "-noout", "-in", cert.path]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return true }
        p.waitUntilExit()
        return p.terminationStatus != 0
    }

    private static func openssl(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        let err = Pipe()
        p.standardOutput = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ProviderError.message("openssl \(args.first ?? "") failed: \(message.prefix(200))")
        }
    }
}
