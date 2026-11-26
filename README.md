# AI Ödev Takip (API Keysiz - Cihaz İçi Vision AI)

Bu proje hiçbir harici API anahtarına veya internet bağlantısına ihtiyaç duymaz. Apple'ın yerleşik **Vision (OCR)** ve doğal dil işleme kurallarını kullanarak tahtadaki Türkçe/İngilizce yazıları doğrudan iPhone üzerinde okur, dersi ve teslim tarihini tahmin edip ödev listesine ekler.

## Klasör İçeriği
- `OdevTakipAI.xcodeproj`: Doğrudan Xcode veya bulut derleme sistemlerinde açılabilen proje dosyası.
- `OdevTakipAI/ContentView.swift`: Ana uygulama arayüzü ve cihaz içi yapay zeka motoru.
- `OdevTakipAI/Info.plist`: Kamera ve fotoğraf galerisi izinleri tanımlı yapılandırma dosyası.
- `codemagic.yaml`: Mac olmadan Codemagic üzerinden `.ipa` derlemek için hazır ayar dosyası.

## Bulut Üzerinden `.ipa` Alma (Mac Gerektirmez)
1. Bu klasörü yeni bir **GitHub** reposuna yükle.
2. **Codemagic.io** hesabına girip bu repoyu bağla.
3. Codemagic ayarlarında **Code signing** kısmına Apple Developer hesabından aldığın `.p12` sertifikasını ve provisioning profile dosyasını ekle.
4. **Start new build** butonuna basarak `.ipa` dosyanı indir.
