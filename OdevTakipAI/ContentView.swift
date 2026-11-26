import SwiftUI
import PhotosUI
import Vision

// MARK: - Veri Modelleri
struct Odev: Identifiable, Codable {
    var id = UUID()
    var baslik: String
    var ders: String
    var teslimTarihi: Date
    var oncelik: Oncelik
    var tamamlandi: Bool = false
}

enum Oncelik: String, Codable, CaseIterable {
    case dusuk = "Düşük"
    case orta = "Orta"
    case yuksek = "Yüksek"
    
    var renk: Color {
        switch self {
        case .dusuk: return .green
        case .orta: return .orange
        case .yuksek: return .red
        }
    }
}

// MARK: - Cihaz İçi Yapay Zeka (Apple Vision OCR + Akıllı Ödev Ayrıştırıcı)
class YerelYapayZekaServisi {
    
    private let dersAnahtarKelimeleri: [String: [String]] = [
        "Matematik": ["mat", "matematik", "türev", "integral", "limit", "fonksiyon", "denklem", "polinom", "trigonometri", "geometri", "üçgen", "çember", "olasılık", "sayfa", "test"],
        "Fizik": ["fizik", "kuvvet", "hareket", "enerji", "elektrik", "manyetizma", "optik", "dalga", "vektör", "ivme", "basınç"],
        "Kimya": ["kimya", "mol", "atom", "periyodik", "asit", "baz", "tepkime", "çözelti", "organik", "bileşik"],
        "Biyoloji": ["biyoloji", "hücre", "dna", "rna", "mitoz", "mayoz", "ekosistem", "kalıtım", "enzim", "sistemler"],
        "Türkçe / Edebiyat": ["türkçe", "edebiyat", "paragraf", "dil bilgisi", "şiir", "roman", "kompozisyon", "özet", "kitap", "fiilimsi", "cümle"],
        "Tarih": ["tarih", "osmanlı", "inkılap", "savaş", "antlaşma", "uygarlık", "cumhuriyet", "devrim"],
        "Coğrafya": ["coğrafya", "iklim", "harita", "nüfus", "yer şekilleri", "bölge", "ekvator"],
        "İngilizce": ["ingilizce", "english", "unit", "workbook", "student's book", "grammar", "vocabulary", "essay", "page"]
    ]
    
    func tahtayiAnalizEt(resim: UIImage) async throws -> [Odev] {
        guard let cgImage = resim.cgImage else {
            throw NSError(domain: "VisionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Görüntü işlenemedi."])
        }
        
        let satirlar = try await metinOku(cgImage: cgImage)
        return satirlardanOdevUret(satirlar: satirlar)
    }
    
    private func metinOku(cgImage: CGImage) async throws -> [String] {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }
                
                // Yukarıdan aşağıya sırala
                let siraliGozlemler = observations.sorted { $0.boundingBox.minY > $1.boundingBox.minY }
                let metinler = siraliGozlemler.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: metinler)
            }
            
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["tr-TR", "en-US"]
            request.usesLanguageCorrection = true
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    private func satirlardanOdevUret(satirlar: [String]) -> [Odev] {
        var cikarilanOdevler: [Odev] = []
        var aktifDers: String = "Genel"
        
        for hamSatir in satirlar {
            let satir = hamSatir.trimmingCharacters(in: .whitespacesAndNewlines)
            if satir.count < 3 { continue }
            
            // Satırın ders başlığı olup olmadığını kontrol et
            let tespitEdilenDers = dersTahminEt(metin: satir)
            let sadeceDersBasligiMi = satir.count <= 18 && tespitEdilenDers != "Genel" && !satir.contains(where: { $0.isNumber })
            
            if sadeceDersBasligiMi {
                aktifDers = tespitEdilenDers
                continue
            }
            
            // Ödev satırı olarak değerlendir
            let ders = tespitEdilenDers != "Genel" ? tespitEdilenDers : aktifDers
            let gunFarki = tarihGunFarkiBul(metin: satir)
            let oncelik = oncelikBelirle(metin: satir, gunFarki: gunFarki)
            let teslimTarihi = Calendar.current.date(byAdding: .day, value: gunFarki, to: Date()) ?? Date()
            
            let temizBaslik = baslikTemizle(satir: satir, dersAdi: ders)
            if !temizBaslik.isEmpty {
                cikarilanOdevler.append(
                    Odev(
                        baslik: temizBaslik,
                        ders: ders,
                        teslimTarihi: teslimTarihi,
                        oncelik: oncelik
                    )
                )
            }
        }
        
        // Eğer tahtada hiç ayrıştırılabilir satır bulunamadıysa ama metin varsa tek ödev yap
        if cikarilanOdevler.isEmpty && !satirlar.isEmpty {
            let birlesik = satirlar.joined(separator: " - ")
            cikarilanOdevler.append(
                Odev(
                    baslik: birlesik,
                    ders: dersTahminEt(metin: birlesik),
                    teslimTarihi: Calendar.current.date(byAdding: .day, value: 2, to: Date()) ?? Date(),
                    oncelik: .orta
                )
            )
        }
        
        return cikarilanOdevler
    }
    
    private func dersTahminEt(metin: String) -> String {
        let kucuk = metin.lowercased(with: Locale(identifier: "tr_TR"))
        for (ders, kelimeler) in dersAnahtarKelimeleri {
            for kelime in kelimeler {
                if kucuk.contains(kelime) {
                    return ders
                }
            }
        }
        return "Genel"
    }
    
    private func tarihGunFarkiBul(metin: String) -> Int {
        let kucuk = metin.lowercased(with: Locale(identifier: "tr_TR"))
        if kucuk.contains("yarın") || kucuk.contains("tomorrow") {
            return 1
        }
        if kucuk.contains("haftaya") || kucuk.contains("next week") {
            return 7
        }
        
        let bugunHaftaninGunu = Calendar.current.component(.weekday, from: Date()) // 1: Pazar, 2: Pzt ... 7: Cmt
        let gunHaritasi: [String: Int] = [
            "pazar": 1, "pazartesi": 2, "salı": 3, "çarşamba": 4,
            "perşembe": 5, "cuma": 6, "cumartesi": 7
        ]
        
        for (gunAdi, hedefGun) in gunHaritasi {
            if kucuk.contains(gunAdi) {
                var fark = hedefGun - bugunHaftaninGunu
                if fark <= 0 { fark += 7 }
                return fark
            }
        }
        
        return 2 // Varsayılan 2 gün sonra
    }
    
    private func oncelikBelirle(metin: String, gunFarki: Int) -> Oncelik {
        let kucuk = metin.lowercased(with: Locale(identifier: "tr_TR"))
        if kucuk.contains("acil") || kucuk.contains("önemli") || kucuk.contains("sınav") || kucuk.contains("proje") || kucuk.contains("!") || gunFarki <= 1 {
            return .yuksek
        }
        if gunFarki >= 5 || kucuk.contains("isteğe bağlı") || kucuk.contains("okuma") {
            return .dusuk
        }
        return .orta
    }
    
    private func baslikTemizle(satir: String, dersAdi: String) -> String {
        var sonuc = satir
        let onEkler = ["ödev:", "odev:", "-", "*", "•"]
        for ek in onEkler {
            if sonuc.lowercased().hasPrefix(ek) {
                sonuc = String(sonuc.dropFirst(ek.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return sonuc
    }
}

// MARK: - Ana Görünüm
struct ContentView: View {
    @State private var odevler: [Odev] = []
    @State private var yeniOdevEkleAcik = false
    @State private var kameraAcik = false
    @State private var secilenFotoItem: PhotosPickerItem?
    @State private var aiYukleniyor = false
    @State private var bilgiMesaji: String?
    @State private var filtreSecimi = 0
    
    private let yapayZeka = YerelYapayZekaServisi()
    let kayitAnahtari = "KayitliOdevler_OfflineAI_v1"
    
    var filtrelenmisOdevler: [Odev] {
        let sirali = odevler.sorted { $0.teslimTarihi < $1.teslimTarihi }
        switch filtreSecimi {
        case 1: return sirali.filter { !$0.tamamlandi }
        case 2: return sirali.filter { $0.tamamlandi }
        default: return sirali
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                VStack {
                    Picker("Filtre", selection: $filtreSecimi) {
                        Text("Tümü").tag(0)
                        Text("Bekleyen").tag(1)
                        Text("Biten").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    
                    if filtrelenmisOdevler.isEmpty {
                        ContentUnavailableView(
                            "Ödev Bulunamadı",
                            systemImage: "camera.viewfinder",
                            description: Text("Tahtanın fotoğrafını çekerek cihaz içi yapay zeka ile ödev ekleyebilir veya sağ üstten manuel giriş yapabilirsin.")
                        )
                    } else {
                        List {
                            ForEach(filtrelenmisOdevler) { odev in
                                OdevSatiri(odev: odev) {
                                    durumDegistir(odev: odev)
                                }
                            }
                            .onDelete(perform: odevSil)
                        }
                        .listStyle(.insetGrouped)
                    }
                }
                
                if aiYukleniyor {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                        Text("Tahta Taranıyor...")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text("Cihaz içi Vision AI metinleri analiz ediyor")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .padding(24)
                    .background(.ultraThinMaterial)
                    .cornerRadius(16)
                }
            }
            .navigationTitle("AI Ödev Takip")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(action: { kameraAcik = true }) {
                        Image(systemName: "camera.fill")
                    }
                    
                    PhotosPicker(selection: $secilenFotoItem, matching: .images) {
                        Image(systemName: "photo.on.rectangle")
                    }
                    
                    Button(action: { yeniOdevEkleAcik = true }) {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $yeniOdevEkleAcik) {
                YeniOdevView { yeniOdev in
                    odevler.append(yeniOdev)
                    verileriKaydet()
                }
            }
            .fullScreenCover(isPresented: $kameraAcik) {
                KameraView { cekilenResim in
                    tahtaFotografiniIsle(resim: cekilenResim)
                }
            }
            .onChange(of: secilenFotoItem) { _, yeniItem in
                Task {
                    if let data = try? await yeniItem?.loadTransferable(type: Data.self),
                       let uiImage = UIImage(data: data) {
                        tahtaFotografiniIsle(resim: uiImage)
                    }
                }
            }
            .alert("Tarama Sonucu", isPresented: Binding(get: { bilgiMesaji != nil }, set: { if !$0 { bilgiMesaji = nil } })) {
                Button("Tamam", role: .cancel) { }
            } message: {
                Text(bilgiMesaji ?? "")
            }
            .onAppear(perform: verileriYukle)
        }
    }
    
    // MARK: - AI İşleme
    private func tahtaFotografiniIsle(resim: UIImage) {
        aiYukleniyor = true
        Task {
            do {
                let bulunanOdevler = try await yapayZeka.tahtayiAnalizEt(resim: resim)
                await MainActor.run {
                    aiYukleniyor = false
                    if bulunanOdevler.isEmpty {
                        bilgiMesaji = "Fotoğrafta okunabilir bir ödev metni bulunamadı. Daha net bir açıdan tekrar dene."
                    } else {
                        odevler.append(contentsOf: bulunanOdevler)
                        verileriKaydet()
                        bilgiMesaji = "\(bulunanOdevler.count) adet ödev tahtadan başarıyla okundu ve eklendi!"
                    }
                }
            } catch {
                await MainActor.run {
                    aiYukleniyor = false
                    bilgiMesaji = "Tarama sırasında hata oluştu: \(error.localizedDescription)"
                }
            }
        }
    }
    
    // MARK: - Standart İşlemler
    private func durumDegistir(odev: Odev) {
        if let index = odevler.firstIndex(where: { $0.id == odev.id }) {
            withAnimation {
                odevler[index].tamamlandi.toggle()
                verileriKaydet()
            }
        }
    }
    
    private func odevSil(at offsets: IndexSet) {
        let silinecekler = offsets.map { filtrelenmisOdevler[$0].id }
        odevler.removeAll { silinecekler.contains($0.id) }
        verileriKaydet()
    }
    
    private func verileriKaydet() {
        if let encoded = try? JSONEncoder().encode(odevler) {
            UserDefaults.standard.set(encoded, forKey: kayitAnahtari)
        }
    }
    
    private func verileriYukle() {
        if let data = UserDefaults.standard.data(forKey: kayitAnahtari),
           let decoded = try? JSONDecoder().decode([Odev].self, from: data) {
            odevler = decoded
        }
    }
}

// MARK: - UIKit Kamera Sarmalayıcı
struct KameraView: UIViewControllerRepresentable {
    @Environment(\.dismiss) var dismiss
    var resimSecildi: (UIImage) -> Void
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
        } else {
            picker.sourceType = .photoLibrary
        }
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: KameraView
        init(_ parent: KameraView) { self.parent = parent }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.resimSecildi(image)
            }
            parent.dismiss()
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Liste Satırı & Manuel Ekleme
struct OdevSatiri: View {
    let odev: Odev
    let toggleAction: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggleAction) {
                Image(systemName: odev.tamamlandi ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundColor(odev.tamamlandi ? .blue : .gray)
            }
            .buttonStyle(.plain)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(odev.baslik)
                    .font(.headline)
                    .strikethrough(odev.tamamlandi)
                    .foregroundColor(odev.tamamlandi ? .secondary : .primary)
                
                HStack {
                    Text(odev.ders)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .cornerRadius(6)
                    
                    Text(odev.teslimTarihi, style: .date)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Text(odev.oncelik.rawValue)
                .font(.caption2)
                .fontWeight(.bold)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(odev.oncelik.renk.opacity(0.15))
                .foregroundColor(odev.oncelik.renk)
                .cornerRadius(8)
        }
        .padding(.vertical, 4)
    }
}

struct YeniOdevView: View {
    @Environment(\.dismiss) var dismiss
    @State private var baslik = ""
    @State private var ders = ""
    @State private var teslimTarihi = Date().addingTimeInterval(86400)
    @State private var oncelik: Oncelik = .orta
    
    var onSave: (Odev) -> Void
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Ödev Bilgileri") {
                    TextField("Ödev Başlığı", text: $baslik)
                    TextField("Ders Adı", text: $ders)
                }
                Section("Detaylar") {
                    DatePicker("Teslim Tarihi", selection: $teslimTarihi, displayedComponents: [.date, .hourAndMinute])
                    Picker("Öncelik", selection: $oncelik) {
                        ForEach(Oncelik.allCases, id: \.self) { seviye in
                            Text(seviye.rawValue).tag(seviye)
                        }
                    }
                }
            }
            .navigationTitle("Yeni Ödev")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("İptal") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") {
                        onSave(Odev(baslik: baslik, ders: ders.isEmpty ? "Genel" : ders, teslimTarihi: teslimTarihi, oncelik: oncelik))
                        dismiss()
                    }
                    .disabled(baslik.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
