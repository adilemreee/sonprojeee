# Cloudflare Tunnel Manager

<img src="Screenshot 2025-05-11 at 11.34.15.png" width="300" height="auto" alt="Cloudflare Tunnel Manager Arayüzü">


## Proje Hakkında

Cloudflare Tunnel Manager, macOS için geliştirilmiş bir tünel yönetim uygulamasıdır. Bu uygulama, Cloudflare tünellerini kolayca yönetmenizi ve yapılandırmanızı sağlar.

## Özellikler

- Cloudflare tüneli oluşturma ve yönetme
- MAMP entegrasyonu ile kolay tünel oluşturma
- Tünel ayarlarını yapılandırma
- Sistem ayarlarına kolay erişim
- Modern ve kullanıcı dostu arayüz

## Gereksinimler

- macOS işletim sistemi
- Cloudflare hesabı
- MAMP (opsiyonel, MAMP entegrasyonu için)

## Kurulum

1. Uygulamayı indirin
2. Uygulamayı Applications klasörüne taşıyın
3. Uygulamayı ilk kez çalıştırdığınızda gerekli izinleri verin

## Kullanım

Detaylı kullanım kılavuzu için `kullanım.pdf` dosyasını inceleyebilirsiniz.

## Proje Yapısı

- `CloudflaredManagerApp.swift`: Ana uygulama yapısı
- `AppDelegate.swift`: Uygulama yaşam döngüsü yönetimi
- `TunnelManager.swift`: Tünel yönetimi işlemleri
- `CreateManagedTunnelView.swift`: Tünel oluşturma arayüzü
- `CreateFromMampView.swift`: MAMP entegrasyonu arayüzü
- `SettingsView.swift`: Ayarlar arayüzü
- `Models.swift`: Veri modelleri
- `ContentView.swift`: Ana görünüm

## Geliştirme

Bu proje SwiftUI kullanılarak geliştirilmiştir ve macOS için özel olarak tasarlanmıştır.

## Lisans

Bu proje özel lisans altında dağıtılmaktadır. Tüm hakları saklıdır.
