# Bacisc Video Editor — Yol Haritası

macOS (M serisi) için native, kişisel kullanımlı basit video editörü.
Teknoloji: Swift, SwiftUI (+ gerektiğinde AppKit), AVFoundation, Core Image / Metal.

## Kararlar

- **Proje = doküman paketi** (`.vedproj`): içinde `project.json` (ayarlar, medya referansları, timeline).
- **Medyalar sadece referans**: dosya yolu + bookmark saklanır, kopyalanmaz. Bulunamayan medya için "çevrimdışı" + "Yeniden bağla" (Faz 2).
- **Ripple silme**: silinen parçanın arkasındaki klipler aynı track'te sola kayar. Linked klipler (ayrılmış ses) birlikte silinir/kayar, overlay'ler yerinde kalır.
- **Veri modeli**: `Project → [Track] → [Clip]`, hepsi `Codable` değer tipleri (`Packages/EditorCore`). AVFoundation nesneleri her değişiklikte modelden yeniden üretilir.
- **Undo**: her düzenleme `ProjectDocument.perform` üzerinden; önceki `Project` değeri saklanır, tek adımda geri alınır.
- **WYSIWYG**: önizleme ve export aynı `CompositionBuilder` (ve Faz 3'te aynı özel compositor) üzerinden geçer.
- **Export v1**: `AVAssetExportSession` presetleri — MP4 (H.264), MOV (HEVC), ProRes; 720p / 1080p / 4K / proje çözünürlüğü; sadece ses için M4A. İnce ayar gerekirse v2'de `AVAssetWriter`.
- **Dağıtım**: App Sandbox kapalı, Personal Team imzası, `scripts/install.sh` ile `/Applications`'a kurulum. Notarization yok.

## Ekran düzeni

```
┌────────────┬──────────────────────────┐
│ Medya      │                          │
│ havuzu     │        Önizleme          │
├────────────┤                          │
│ Araçlar    │                          │
│ (tek tık)  │                          │
├────────────┴──────────────────────────┤
│ Timeline (tam genişlik, çoklu track)  │
└───────────────────────────────────────┘
```

## Fazlar

1. **İskelet + temel kurgu** — doküman tipi, ekran düzeni, medya havuzu (sürükle-bırak, thumbnail), tek video track, oynatma/scrub, bölme (`B` / `⌘K`), ripple silme (`Delete`), undo, kurulum scripti.
2. **Ses** — sesi ayırma (linked klip), ses track'leri, dalga formu, ses seviyesi; çevrimdışı medya + yeniden bağlama.
3. **Katmanlar** — özel `AVVideoCompositing` (Core Image + Metal), metin / görsel / video overlay, önizlemede transform tutamaçları, track başlığından sürükleyerek z-index.
4. **Export** — preset sheet, ilerleme + iptal, M4A.
5. **Cila** — snapping, zoom iyileştirmeleri, filmstrip thumbnail, kısayollar, araçlar paneline yeni tek tık butonları.

## Geliştirme

```bash
swift test --package-path Packages/EditorCore   # model testleri
xcodebuild -scheme bacisc-video-editor build     # uygulama
scripts/install.sh                               # Release derle, /Applications'a kur
```
