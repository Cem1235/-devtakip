import SwiftUI
import PhotosUI
import Vision

// MARK: - Veri Modelleri
struct Odev: Identifiable, Codable, Equatable {
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

struct DersRenk {
    static func renk(for ders: String) -> Color {
        switch ders {
        case "Türkçe": return .indigo
        case "İngilizce": return .blue
        case "Matematik": return .purple
        case "Fizik": return .cyan
        case "Kimya": return .teal
        case "Biyoloji": return .green
        case "Tarih": return .brown
        case "Coğrafya": return .mint
        default: return .gray
        }
    }
}

// MARK: - Gelişmiş Cihaz İçi Tahta Okuma ve Ödev Ayrıştırma Motoru
class TahtaOkumaServisi {
    
    // Ders başlığı olarak kabul edilecek kalıplar
    private let dersBasliklari: [(ders: String, anahtarlar: [String])] = [
        ("Türkçe", ["türkçe", "turkce", "edebiyat"]),
        ("İngilizce", ["ingilizce", "ing", "english"]),
        ("Matematik", ["matematik", "mat", "geometri"]),
        ("Fizik", ["fizik"]),
        ("Kimya", ["kimya"]),
        ("Biyoloji", ["biyoloji"]),
        ("Tarih", ["tarih", "inkılap"]),
        ("Coğrafya", ["coğrafya", "cografya"])
    ]
    
    // İçerik üzerinden ders tahmini (başlık yoksa)
    private let icerikAnahtarlari: [(ders: String, anahtarlar: [String])] = [
        ("İngilizce", ["student book", "workbook", "project explore", "unit", "vocabulary", "grammar", "page"]),
        ("Türkçe", ["paragraf", "dil bilgisi", "fiilimsi", "şiir", "roman", "kompozisyon", "özet"]),
        ("Matematik", ["türev", "integral", "limit", "fonksiyon", "denklem", "polinom", "trigonometri", "üçgen", "çember"]),
        ("Fizik", ["kuvvet", "hareket", "enerji", "elektrik", "manyetizma", "optik", "vektör"]),
        ("Kimya", ["mol", "atom", "periyodik", "asit", "baz", "tepkime", "çözelti"]),
        ("Biyoloji", ["hücre", "dna", "rna", "mitoz", "mayoz", "ekosistem", "kalıtım"])
    ]
    
    func tahtayiAnalizEt(resim: UIImage) async throws -> [Odev] {
        guard let cgImage = resim.cgImage else {
            throw NSError(domain: "VisionError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Görüntü işlenemedi."])
        }
        
        let gozlemler = try await metinBloklariniOku(cgImage: cgImage)
        return bloklardanOdevUret(gozlemler: gozlemler)
    }
    
    private func metinBloklariniOku(cgImage: CGImage) async throws -> [(metin: String, rect: CGRect)] {
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
                
                // Y koordinatına göre yukarıdan aşağıya sırala (Vision'da Y alttan başlar, büyük Y üsttedir)
                let sirali = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                let sonuclar: [(String, CGRect)] = sirali.compactMap { obs in
                    guard let str = obs.topCandidates(1).first?.string else { return nil }
                    return (str, obs.boundingBox)
                }
                continuation.resume(returning: sonuclar)
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
    
    private func bloklardanOdevUret(gozlemler: [(metin: String, rect: CGRect)]) -> [Odev] {
        // 1. Adım: Kenarda kesilmiş anlamsız 1-3 harflik gürültüleri (örn. "ca.", "sea.") ele
        let temizGozlemler = gozlemler.filter { item in
            let t = item.metin.trimmingCharacters(in: .whitespacesAndNewlines)
            // Çok solda veya sağda kesilmiş kısa kelimeleri at
            if t.count <= 4 && (item.rect.minX < 0.08 || item.rect.maxX > 0.96) {
                return false
            }
            return t.count >= 2
        }
        
        // 2. Adım: Aynı satır hizasındaki parçaları (örn: "Soru Bankası s.105'ten" + "114'e kadar.") birleştir
        var satirGruplari: [[(metin: String, rect: CGRect)]] = []
        for item in temizGozlemler {
            if let sonGrupIndex = satirGruplari.indices.last,
               let sonItem = satirGruplari[sonGrupIndex].last,
               abs(item.rect.midY - sonItem.rect.midY) < 0.025 {
                satirGruplari[sonGrupIndex].append(item)
            } else {
                satirGruplari.append([item])
            }
        }
        
        let birlesikSatirlar: [(metin: String, rect: CGRect)] = satirGruplari.map { grup in
            let soldanSaga = grup.sorted { $0.rect.minX < $1.rect.minX }
            let metin = soldanSaga.map { $0.metin }.joined(separator: " ")
            let ilkRect = soldanSaga.first!.rect
            return (ocrDuzelt(metin), ilkRect)
        }
        
        // 3. Adım: Ders başlıklarını tespit et ve altındaki satırları mantıklı ödev bloklarına ayır
        var cikarilanOdevler: [Odev] = []
        var aktifDers: String = "Genel"
        var dersBasligiTanimlandi = false
        
        var mevcutOdevSatirlari: [String] = []
        var mevcutTeslimGunu: Int? = nil
        
        func mevcutOdeviKaydet() {
            guard !mevcutOdevSatirlari.isEmpty else { return }
            let birlesikBaslik = mevcutOdevSatirlari.joined(separator: " - ")
            let nihaiDers = dersBasligiTanimlandi ? aktifDers : iceriktenDersTahminEt(birlesikBaslik)
            let gun = mevcutTeslimGunu ?? 2
            let tarih = Calendar.current.date(byAdding: .day, value: gun, to: Date()) ?? Date()
            let oncelik = oncelikBelirle(metin: birlesikBaslik, gunFarki: gun)
            
            cikarilanOdevler.append(
                Odev(
                    baslik: birlesikBaslik,
                    ders: nihaiDers,
                    teslimTarihi: tarih,
                    oncelik: oncelik
                )
            )
            mevcutOdevSatirlari = []
            mevcutTeslimGunu = nil
        }
        
        for item in birlesikSatirlar {
            let satir = item.metin.trimmingCharacters(in: .whitespacesAndNewlines)
            if satir.isEmpty { continue }
            
            // Bu satır bir ders başlığı mı? (Örn: "Türkçe", "İNG (serra)", "Matematik")
            if let bulunanDers = dersBasligiMi(satir) {
                mevcutOdeviKaydet()
                aktifDers = bulunanDers
                dersBasligiTanimlandi = true
                continue
            }
            
            // Sadece gün/tarih bildiren alt satır mı? (Örn: "Pazartesine", "Cumaya", "Yarına")
            if let gunFarki = sadeceTarihSatiriMi(satir) {
                if !mevcutOdevSatirlari.isEmpty {
                    mevcutTeslimGunu = gunFarki
                    mevcutOdeviKaydet()
                }
                continue
            }
            
            // Önceki satırın devamı niteliğinde mi? (Örn: "114'e kadar.", "Student book", "Sf 32,34,35")
            if mevcutOdevSatirlari.isEmpty {
                mevcutOdevSatirlari.append(satir)
                if let icerikGunu = metinIcindeGunBul(satir) {
                    mevcutTeslimGunu = icerikGunu
                }
            } else if devamSatiriMi(satir) {
                mevcutOdevSatirlari.append(satir)
                if let icerikGunu = metinIcindeGunBul(satir) {
                    mevcutTeslimGunu = icerikGunu
                }
            } else {
                // Yeni ve bağımsız bir ödev satırı (Örn: "Test 10/11/12/13/14")
                mevcutOdeviKaydet()
                mevcutOdevSatirlari.append(satir)
                if let icerikGunu = metinIcindeGunBul(satir) {
                    mevcutTeslimGunu = icerikGunu
                }
            }
        }
        
        mevcutOdeviKaydet()
        return cikarilanOdevler
    }
    
    // Yaygın el yazısı OCR hatalarını düzeltir
    private func ocrDuzelt(_ metin: String) -> String {
        var s = metin
        let duzeltmeler: [(String, String)] = [
            ("105 Hen", "105'ten"),
            ("105'Hen", "105'ten"),
            ("Expbr", "Explore"),
            ("Explre", "Explore"),
            ("Pazarzesine", "Pazartesine"),
            ("Pazartesire", "Pazartesine"),
            ("iNG", "İNG"),
            ("Sf ", "Sayfa "),
            ("sf ", "Sayfa "),
            ("s.", "Sayfa ")
        ]
        for (yanlis, dogru) in duzeltmeler {
            s = s.replacingOccurrences(of: yanlis, with: dogru)
        }
        return s
    }
    
    private func dersBasligiMi(_ satir: String) -> String? {
        // Parantez içi öğretmen adını temizle (örn: "İNG (serra)" -> "ing")
        let temiz = satir
            .replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "tr_TR"))
        
        // Başlıklar genelde kısadır ve sayfa/test numarası içermez
        if temiz.count > 16 || temiz.contains(where: { $0.isNumber }) {
            return nil
        }
        
        for (ders, anahtarlar) in dersBasliklari {
            for anahtar in anahtarlar {
                if temiz == anahtar || temiz.hasPrefix(anahtar) {
                    return ders
                }
            }
        }
        return nil
    }
    
    private func iceriktenDersTahminEt(_ metin: String) -> String {
        let kucuk = metin.lowercased(with: Locale(identifier: "tr_TR"))
        for (ders, anahtarlar) in icerikAnahtarlari {
            for anahtar in anahtarlar {
                if kucuk.contains(anahtar) {
                    return ders
                }
            }
        }
        return "Genel"
    }
    
    private func devamSatiriMi(_ satir: String) -> Bool {
        let kucuk = satir.lowercased(with: Locale(identifier: "tr_TR"))
        let devamKalıplari = ["kadar", "student book", "workbook", "sayfa", "sf", "ünite", "unit", "bölüm", "kısım"]
        if devamKalıplari.contains(where: { kucuk.contains($0) }) {
            return true
        }
        if let ilkKarakter = satir.first, ilkKarakter.isLowercase {
            return true
        }
        return false
    }
    
    private func sadeceTarihSatiriMi(_ satir: String) -> Int? {
        let kucuk = satir.lowercased(with: Locale(identifier: "tr_TR"))
        if kucuk.count <= 16 {
            return metinIcindeGunBul(kucuk)
        }
        return nil
    }
    
    private func metinIcindeGunBul(_ metin: String) -> Int? {
        let kucuk = metin.lowercased(with: Locale(identifier: "tr_TR"))
        if kucuk.contains("yarın") || kucuk.contains("yarına") { return 1 }
        if kucuk.contains("haftaya") { return 7 }
        
        let bugun = Calendar.current.component(.weekday, from: Date())
        let gunler: [(String, Int)] = [
            ("pazar", 1), ("pazartesi", 2), ("salı", 3), ("çarşamba", 4),
            ("perşembe", 5), ("cuma", 6), ("cumartesi", 7)
        ]
        // "pazartesi" kelimesi "pazar"ı da içerdiği için önce uzun olanları kontrol et
        for (gunAdi, hedef) in gunler.sorted(by: { $0.0.count > $1.0.count }) {
            if kucuk.contains(gunAdi) {
                var fark = hedef - bugun
                if fark <= 0 { fark += 7 }
                return fark
            }
        }
        return nil
    }
    
    private func oncelikBelirle(metin: String, gunFarki: Int) -> Oncelik {
        let kucuk = metin.lowercased(with: Locale(identifier: "tr_TR"))
        if kucuk.contains("acil") || kucuk.contains("önemli") || kucuk.contains("sınav") || kucuk.contains("proje") || gunFarki <= 1 {
            return .yuksek
        }
        if gunFarki >= 5 {
            return .dusuk
        }
        return .orta
    }
}

// MARK: - Ana Görünüm
struct ContentView: View {
    @State private var odevler: [Odev] = []
    @State private var yeniOdevEkleAcik = false
    @State private var duzenlenecekOdev: Odev?
    @State private var kameraAcik = false
    @State private var secilenFotoItem: PhotosPickerItem?
    @State private var taramaYapiliyor = false
    @State private var bilgiMesaji: String?
    @State private var filtreSecimi = 0
    
    private let tahtaServisi = TahtaOkumaServisi()
    let kayitAnahtari = "KayitliOdevler_v3"
    
    var bekleyenSayisi: Int { odevler.filter { !$0.tamamlandi }.count }
    var bitenSayisi: Int { odevler.filter { $0.tamamlandi }.count }
    
    var filtrelenmisOdevler: [Odev] {
        let sirali = odevler.sorted {
            if $0.tamamlandi != $1.tamamlandi { return !$0.tamamlandi }
            return $0.teslimTarihi < $1.teslimTarihi
        }
        switch filtreSecimi {
        case 1: return sirali.filter { !$0.tamamlandi }
        case 2: return sirali.filter { $0.tamamlandi }
        default: return sirali
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()
                
                VStack(spacing: 12) {
                    // Üst Özet Kartları
                    HStack(spacing: 12) {
                        OzetKarti(
                            baslik: "Bekleyen",
                            sayi: bekleyenSayisi,
                            ikon: "clock.badge.exclamationmark",
                            renk: .blue
                        )
                        OzetKarti(
                            baslik: "Tamamlanan",
                            sayi: bitenSayisi,
                            ikon: "checkmark.seal.fill",
                            renk: .green
                        )
                    }
                    .padding(.horizontal)
                    .padding(.top, 4)
                    
                    // Filtre Seçici
                    Picker("Filtre", selection: $filtreSecimi) {
                        Text("Tümü (\(odevler.count))").tag(0)
                        Text("Bekleyen").tag(1)
                        Text("Biten").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    
                    if filtrelenmisOdevler.isEmpty {
                        Spacer()
                        ContentUnavailableView(
                            "Ödev Listesi Boş",
                            systemImage: "text.viewfinder",
                            description: Text("Tahtanın fotoğrafını çekerek veya galeriden seçerek ödevlerini otomatik ekleyebilirsin.")
                        )
                        Spacer()
                    } else {
                        List {
                            ForEach(filtrelenmisOdevler) { odev in
                                OdevSatiri(odev: odev) {
                                    durumDegistir(odev: odev)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    duzenlenecekOdev = odev
                                }
                            }
                            .onDelete(perform: odevSil)
                        }
                        .listStyle(.insetGrouped)
                    }
                }
                
                if taramaYapiliyor {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView()
                            .scaleEffect(1.4)
                            .tint(.white)
                        Text("Tahta Okunuyor...")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text("Yazılar ve ders başlıkları düzenleniyor")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .padding(24)
                    .background(.ultraThinMaterial)
                    .cornerRadius(18)
                }
            }
            .navigationTitle("Ödevlerim")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(action: { kameraAcik = true }) {
                        Image(systemName: "camera.fill")
                            .font(.body.weight(.semibold))
                    }
                    
                    PhotosPicker(selection: $secilenFotoItem, matching: .images) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.body.weight(.semibold))
                    }
                    
                    Button(action: { yeniOdevEkleAcik = true }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                }
            }
            .sheet(isPresented: $yeniOdevEkleAcik) {
                OdevFormView(baslikMetni: "Yeni Ödev") { yeniOdev in
                    odevler.append(yeniOdev)
                    verileriKaydet()
                }
            }
            .sheet(item: $duzenlenecekOdev) { secilen in
                OdevFormView(baslikMetni: "Ödevi Düzenle", mevcutOdev: secilen) { guncelOdev in
                    if let idx = odevler.firstIndex(where: { $0.id == guncelOdev.id }) {
                        odevler[idx] = guncelOdev
                        verileriKaydet()
                    }
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
                    secilenFotoItem = nil
                }
            }
            .alert("Tahta Taraması", isPresented: Binding(get: { bilgiMesaji != nil }, set: { if !$0 { bilgiMesaji = nil } })) {
                Button("Tamam", role: .cancel) { }
            } message: {
                Text(bilgiMesaji ?? "")
            }
            .onAppear(perform: verileriYukle)
        }
    }
    
    // MARK: - Tahta Görüntüsü İşleme
    private func tahtaFotografiniIsle(resim: UIImage) {
        taramaYapiliyor = true
        Task {
            do {
                let bulunanOdevler = try await tahtaServisi.tahtayiAnalizEt(resim: resim)
                await MainActor.run {
                    taramaYapiliyor = false
                    if bulunanOdevler.isEmpty {
                        bilgiMesaji = "Fotoğrafta okunabilir bir ödev bulunamadı. Daha net bir açıdan tekrar dene."
                    } else {
                        odevler.append(contentsOf: bulunanOdevler)
                        verileriKaydet()
                        bilgiMesaji = "\(bulunanOdevler.count) adet ödev tahtadan eklendi. Düzenlemek için üzerine dokunabilirsin."
                    }
                }
            } catch {
                await MainActor.run {
                    taramaYapiliyor = false
                    bilgiMesaji = "Okuma sırasında hata oluştu: \(error.localizedDescription)"
                }
            }
        }
    }
    
    // MARK: - Veri İşlemleri
    private func durumDegistir(odev: Odev) {
        if let index = odevler.firstIndex(where: { $0.id == odev.id }) {
            withAnimation(.snappy) {
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

// MARK: - Üst Özet Kartı
struct OzetKarti: View {
    let baslik: String
    let sayi: Int
    let ikon: String
    let renk: Color
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(baslik)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                Text("\(sayi)")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
            }
            Spacer()
            Image(systemName: ikon)
                .font(.title2)
                .foregroundColor(renk)
                .padding(10)
                .background(renk.opacity(0.12))
                .clipShape(Circle())
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(14)
    }
}

// MARK: - Liste Satırı
struct OdevSatiri: View {
    let odev: Odev
    let toggleAction: () -> Void
    
    var dersRengi: Color {
        DersRenk.renk(for: odev.ders)
    }
    
    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggleAction) {
                Image(systemName: odev.tamamlandi ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundColor(odev.tamamlandi ? .green : .secondary)
            }
            .buttonStyle(.plain)
            
            VStack(alignment: .leading, spacing: 6) {
                Text(odev.baslik)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .strikethrough(odev.tamamlandi)
                    .foregroundColor(odev.tamamlandi ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                
                HStack(spacing: 8) {
                    Text(odev.ders)
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(dersRengi.opacity(0.15))
                        .foregroundColor(dersRengi)
                        .cornerRadius(6)
                    
                    Label {
                        Text(odev.teslimTarihi, style: .date)
                    } icon: {
                        Image(systemName: "calendar")
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Text(odev.oncelik.rawValue)
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(odev.oncelik.renk.opacity(0.14))
                .foregroundColor(odev.oncelik.renk)
                .cornerRadius(8)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Ödev Ekleme ve Düzenleme Formu
struct OdevFormView: View {
    @Environment(\.dismiss) var dismiss
    let baslikMetni: String
    var mevcutOdev: Odev?
    var onSave: (Odev) -> Void
    
    @State private var baslik = ""
    @State private var ders = "Genel"
    @State private var teslimTarihi = Date().addingTimeInterval(86400)
    @State private var oncelik: Oncelik = .orta
    
    let dersSecenekleri = ["Genel", "Türkçe", "İngilizce", "Matematik", "Fizik", "Kimya", "Biyoloji", "Tarih", "Coğrafya"]
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Ödev Detayı") {
                    TextField("Ödev açıklaması", text: $baslik, axis: .vertical)
                        .lineLimit(2...4)
                    
                    Picker("Ders", selection: $ders) {
                        ForEach(dersSecenekleri, id: \.self) { d in
                            Text(d).tag(d)
                        }
                    }
                }
                
                Section("Zamanlama ve Öncelik") {
                    DatePicker("Teslim Tarihi", selection: $teslimTarihi, displayedComponents: [.date])
                    
                    Picker("Öncelik", selection: $oncelik) {
                        ForEach(Oncelik.allCases, id: \.self) { seviye in
                            Text(seviye.rawValue).tag(seviye)
                        }
                    }
                }
            }
            .navigationTitle(baslikMetni)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let odev = mevcutOdev {
                    baslik = odev.baslik
                    ders = dersSecenekleri.contains(odev.ders) ? odev.ders : "Genel"
                    teslimTarihi = odev.teslimTarihi
                    oncelik = odev.oncelik
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("İptal") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") {
                        var kaydedilecek = mevcutOdev ?? Odev(baslik: baslik, ders: ders, teslimTarihi: teslimTarihi, oncelik: oncelik)
                        kaydedilecek.baslik = baslik.trimmingCharacters(in: .whitespacesAndNewlines)
                        kaydedilecek.ders = ders
                        kaydedilecek.teslimTarihi = teslimTarihi
                        kaydedilecek.oncelik = oncelik
                        onSave(kaydedilecek)
                        dismiss()
                    }
                    .disabled(baslik.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - Kamera Sarmalayıcı
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
