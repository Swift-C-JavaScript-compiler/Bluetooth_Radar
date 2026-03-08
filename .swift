import SwiftUI
import CoreBluetooth
import Network
import MultipeerConnectivity
import AVFoundation
import ExternalAccessory
import WebKit

// --- 1. MODELLO DATI ---
struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    let identifier: UUID
    let name: String?
    let rssi: Int
}

// --- 2. MANAGER TOTALE ---
class ShieldSystemManager: NSObject, ObservableObject, CBCentralManagerDelegate, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    
    @Published var discoveredPeripherals = [DiscoveredDevice]()
    @Published var isScanning = false
    @Published var availablePeers: [MCPeerID] = []
    @Published var connectedPeers: [MCPeerID] = []
    
    private var centralManager: CBCentralManager?
    private var peripheralsMap = [UUID: CBPeripheral]()
    
    // Multipeer (Classroom)
    private let myPeerId = MCPeerID(displayName: UIDevice.current.name)
    private let serviceType = "shield-setup"
    private var mcSession: MCSession
    private var mcAdvertiser: MCNearbyServiceAdvertiser
    private var mcBrowser: MCNearbyServiceBrowser
    
    override init() {
        mcSession = MCSession(peer: myPeerId, securityIdentity: nil, encryptionPreference: .required)
        mcAdvertiser = MCNearbyServiceAdvertiser(peer: myPeerId, discoveryInfo: nil, serviceType: serviceType)
        mcBrowser = MCNearbyServiceBrowser(peer: myPeerId, serviceType: serviceType)
        super.init()
        mcSession.delegate = self
        mcAdvertiser.delegate = self
        mcBrowser.delegate = self
        startRadar()
        mcAdvertiser.startAdvertisingPeer()
        mcBrowser.startBrowsingForPeers()
    }
    
    // --- AZIONE: CONNETTI E APRI IMPOSTAZIONI (RIPRISTINATA) ---
    func connectAndOpenSettings(for deviceID: UUID) {
        guard let peripheral = peripheralsMap[deviceID] else { return }
        
        // 1. Tenta connessione per svegliare il dispositivo
        centralManager?.connect(peripheral, options: nil)
        
        // 2. Beep di conferma
        AudioServicesPlaySystemSound(1103)
        
        // 3. Salta alle Impostazioni Bluetooth (Fix per iPad)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let url = URL(string: "App-Prefs:root=Bluetooth") {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        }
    }
    
    // --- RADAR & AUDIO ---
    func startRadar() { centralManager = CBCentralManager(delegate: self, queue: nil) }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            isScanning = true
            centralManager?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        peripheralsMap[peripheral.identifier] = peripheral
        let device = DiscoveredDevice(id: peripheral.identifier, identifier: peripheral.identifier, name: peripheral.name, rssi: Int(truncating: RSSI))
        DispatchQueue.main.async {
            if let index = self.discoveredPeripherals.firstIndex(where: { $0.id == peripheral.identifier }) {
                if device.rssi > -50 && self.discoveredPeripherals[index].rssi <= -50 { AudioServicesPlaySystemSound(1051) }
                self.discoveredPeripherals[index] = device
            } else {
                AudioServicesPlaySystemSound(1103)
                self.discoveredPeripherals.append(device)
            }
        }
    }
    
    // --- CLASSROOM LOGIC ---
    func invitePeer(_ peerID: MCPeerID) { mcBrowser.invitePeer(peerID, to: mcSession, withContext: nil, timeout: 10) }
    func browser(_ b: MCNearbyServiceBrowser, foundPeer p: MCPeerID, withDiscoveryInfo i: [String : String]?) {
        DispatchQueue.main.async { if !self.availablePeers.contains(p) { self.availablePeers.append(p) } }
    }
    func browser(_ b: MCNearbyServiceBrowser, lostPeer p: MCPeerID) {
        DispatchQueue.main.async { self.availablePeers.removeAll { $0 == p } }
    }
    func advertiser(_ a: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer p: MCPeerID, withContext c: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, mcSession)
    }
    func session(_ s: MCSession, peer p: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { self.connectedPeers = s.connectedPeers }
    }
    
    // Metodi sessione richiesti (vuoti)
    func session(_ s: MCSession, didReceive d: Data, fromPeer p: MCPeerID) {}
    func session(_ s: MCSession, didReceive st: InputStream, withName n: String, fromPeer p: MCPeerID) {}
    func session(_ s: MCSession, didStartReceivingResourceWithName n: String, fromPeer p: MCPeerID, with pr: Progress) {}
    func session(_ s: MCSession, didFinishReceivingResourceWithName n: String, fromPeer p: MCPeerID, at l: URL?, withError e: Error?) {}
}

// --- 3. MANAGER RETE (WIXFI) ---
class NetworkGuardManager: ObservableObject {
    @Published var status = "Analisi..."
    @Published var isSecure = false
    private let monitor = NWPathMonitor()
    init() {
        monitor.pathUpdateHandler = { path in
            DispatchQueue.main.async {
                let vpn = path.availableInterfaces.contains(where: { $0.name.contains("utun") })
                self.isSecure = path.status == .satisfied || vpn
                self.status = path.usesInterfaceType(.wifi) ? "Wi-Fi - \(self.isSecure ? "Sicuro" : "Vulnerabile")" : "Rete Dati"
            }
        }; monitor.start(queue: DispatchQueue.global())
    }
}

// --- 4. VIEW ---
struct ContentView: View {
    @StateObject var system = ShieldSystemManager()
    @StateObject var net = NetworkGuardManager()
    @State private var showWeb = false
    
    @StateObject var auth = AuthManager()
    
    @StateObject var cookieManager = CookieManager()
    
    var body: some View {
        NavigationView {
            List {
                // RADAR BLUETOOTH (Tocco sulla riga ripristinato)
                Section(header: Text("Radar Bluetooth (Difesa Fisica)")) {
                    ForEach(system.discoveredPeripherals) { d in
                        Button(action: { system.connectAndOpenSettings(for: d.id) }) {
                            VStack(alignment: .leading) {
                                HStack {
                                    Text(d.name ?? "Dispositivo Ignoto").font(.headline).foregroundColor(.primary)
                                    Spacer()
                                    Text("\(d.rssi) dBm").foregroundColor(d.rssi > -50 ? .red : .blue).font(.caption.monospaced())
                                }
                                Text(d.identifier.uuidString).font(.caption2).foregroundColor(.gray)
                            }
                        }
                    }
                }
                
                // WIXFI & COOKIES
                Section(header: Text("Network & Privacy")) {
                    Label(net.status, systemImage: net.isSecure ? "shield.fill" : "exclamationmark.shield.fill").foregroundColor(net.isSecure ? .green : .orange)
                    Button("Ispeziona Cookie Sandbox") { showWeb = true }
                }
            }
            
            Section(header: Text("Account Gestito")) {
                Button(action: { auth.signInWithGoogle() }) {
                    HStack {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                        Text(auth.isLoggedIn ? "Account Google Connesso" : "Accedi con Google")
                    }
                }
                .foregroundColor(auth.isLoggedIn ? .green : .blue)
            }
            
            Section(header: Text("Analisi Sessione Google")) {
                Button("Apri Login Gestito") { showWeb = true }
                
                ForEach(cookieManager.detectedCookies, id: \.name) { cookie in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(cookie.name).font(.caption.bold())
                            Text(cookie.domain).font(.caption2).foregroundColor(.gray)
                        }
                        Spacer()
                        Image(systemName: "lock.shield").foregroundColor(.green)
                    }
                }
            }
        }
        .sheet(isPresented: $showWeb) { 
            WebView(url: URL(string: "https://accounts.google.com")!, cookieManager: cookieManager) 
        }
    }
}

struct WebView: UIViewRepresentable {
    let url: URL
    let cookieManager: CookieManager // Passiamo il manager
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 Mobile/15E148 Safari/604.1"
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        uiView.load(URLRequest(url: url))
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebView
        init(_ parent: WebView) { self.parent = parent }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Appena il login o la navigazione finisce, sniffiamo i cookie
            parent.cookieManager.fetchGoogleCookies()
        }
    }
}

import AuthenticationServices

class AuthManager: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published var isLoggedIn = false
    
    func signInWithGoogle() {
        // NOTA: Sostituisci con il tuo Client ID ottenuto dalla console Google Cloud
        let authURL = URL(string: "https://accounts.google.com")!
        
        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "com.tuo.bundle.id") { callbackURL, error in
            guard error == nil, let successURL = callbackURL else { return }
            
            // Qui estrai il token dal callbackURL e logghi l'utente
            print("Login effettuato: \(successURL)")
            DispatchQueue.main.async { self.isLoggedIn = true }
        }
        
        session.presentationContextProvider = self
        session.start()
    }
    
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return UIApplication.shared.windows.first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

import WebKit

class CookieManager: NSObject, ObservableObject {
    @Published var detectedCookies: [HTTPCookie] = []
    
    func fetchGoogleCookies() {
        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        
        cookieStore.getAllCookies { cookies in
            DispatchQueue.main.async {
                // Filtriamo solo i cookie di dominio Google per la Sandbox
                self.detectedCookies = cookies.filter { $0.domain.contains("google.com") }
                
                for cookie in self.detectedCookies {
                    print("🛡️ Shield Debug - Cookie trovato: \(cookie.name) = \(cookie.value)")
                }
            }
        }
    }
}
