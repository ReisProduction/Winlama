# Winlama 26.8.6
Winlama; Ollama, Open WebUI, ComfyUI, Whisper ve istege bagli Turkce veya Ingilizce TTS bilesenlerini Windows uzerinde kuran, dogrulayan ve yoneten PowerShell tabanli yerel yapay zeka paketidir. Hedefi, bir Windows bilgisayari yerel yapay zeka sunucusuna donusturup Open WebUI'i guvenilir yerel agdan kullanmaktir.
Bu surum internete dogrudan yayinlanmak icin degil, kimlik dogrulamasi etkin guvenilir LAN kullanimi icin guvenli varsayilanlarla hazirlanmistir.
## Bilesenler
| Bilesen | Surum veya model | Sunucu adresi | Ag erisimi |
|---|---|---|---|
| Ollama | `0.32.5` ve `qwen3.5:4b` | `http://127.0.0.1:11434` | Yalnizca yerel |
| Open WebUI | `0.11.0` | `http://127.0.0.1:3000` | Yerel ag |
| ComfyUI | `0.32.0` tasinabilir NVIDIA paketi | `http://127.0.0.1:8188` | Yalnizca yerel |
| STT | Whisper `base` | Open WebUI icinde | Yalnizca yerel |
| TTS | `facebook/mms-tts-tur` veya `facebook/mms-tts-eng` | `http://127.0.0.1:8880` | Yalnizca yerel |
Open WebUI `0.0.0.0:3000` uzerinde dinler. Kurulum, `netsh advfirewall` ile bu portu yalniz `LocalSubnet` istemcilerine acar. Standart Ollama uygulamasi `::` dinleyicisi kullansa bile `11434` portu kalici blok kuraliyla dis agdan kapatilir; yerel API calismaya devam eder. Konsolda hem `http://127.0.0.1:3000` hem de diger cihazlarin kullanacagi gercek `http://LAN-IP:3000` adresi gosterilir.
## Gereksinimler
- x64 Windows 10 22H2 veya Windows 11; yayin kabul hedefi guncel Windows 11'dir
- Cevrimici kurulum icin internet ve tam 36 dosyalik operasyonel Winlama agaci
- `Local` kaynak icin secilen bilesenlerin dogrulanmis `Runtime` ve `Models` icerigi
- En az PowerShell `7.6.0`; `RunMe.bat` gerekirse dogrulanmis `7.6.3` paketini kurar
- Open WebUI veya ses ozellikleri secilirse uyumlu x64 Python `3.11` veya `3.12`; yoksa otomatik ve sessiz kurulan Python `3.11.9`
- Gorsel ve video uretimi icin guncel NVIDIA surucusu gerekir; Winlama ekran karti surucusunu otomatik kurmaz
- Modeller icin yeterli RAM ve disk alani
RTX 3060 Ti 8 GB; `qwen3.5:4b`, Whisper base ve Turkce MMS TTS icin yeterlidir. Wan2.1 1.3B dusuk VRAM yaklasimiyla kullanilabilir ancak video uretimi yavastir. FLUX.1-schnell FP8 yaklasik 16,06 GB indirme ve calisma sirasinda yaklasik 12 GB alan ister; 8 GB VRAM'de sistem bellegine aktarim nedeniyle yavaslayabilir.
## Kurulum
1. Tam 36 dosyalik operasyonel Winlama agacini yerel diske kopyalayin. Yalniz `.ps1` dosyalari yeterli degildir. `Local` kaynak kullanacaksaniz ayni kokte secilen bilesenlerin dogrulanmis `Runtime` ve `Models` icerigini de koyun.
2. `RunMe.bat` dosyasini calistirin.
3. Ana menuden kurulumu baslatin.
4. Ollama'nin kullanilip kurulmayacagini secin.
5. Ollama secildiyse donanima gore genel, kodlama ve arac/ajan onerilerini inceleyip modelleri secin veya model adimini atlayin.
6. ComfyUI'in kurulup kurulmayacagini, secildiyse gorsel/video modellerini belirleyin.
7. Open WebUI ve yerel ses koprusunu birbirinden bagimsiz secin.
8. Open WebUI secildiyse onerilen guvenli varsayilan yapilandirmanin uygulanip uygulanmayacagini secin.
9. PowerShell, Visual C++, gerekli ise Python ve ComfyUI icin yerel, resmi cevrimici veya otomatik kaynak politikasini secin. Ollama kurucusu veya model paketi yerelde bulunursa anlamli yerel/cevrimici secimi gosterilir; yerel aday yoksa resmi cevrimici kaynak otomatik kullanilir. Voice secilirse Turkce veya Ingilizce TTS modelini belirleyin. TTS modeli dogrulanmis sabit Hugging Face revizyonundan cevrimici alinir; hazir yerel onbellek yoksa Voice secimi internet gerektirir.
10. Son soruda opsiyonel bir bilesen hata verirse kurulumun durmasini veya o bilesenin atlanip devam edilmesini secin.
11. Butun sorular tamamlanana kadar buyuk model SHA-256, ComfyUI agac kimligi veya indirme islemi baslamaz. Son sorudan sonra kaynaklar tam dogrulanir ve kurulum yeni soru sormadan gozetimsiz devam eder; tamamlandiginda yalniz etkin bilesenlerin gosterilen adreslerini acin.
12. Open WebUI secildiyse ilk hesabi olusturun; ilk hesap yonetici olur.
Uygulama sorularinda yalniz tam `EVET`, `HAYIR` veya `0`; model sorularinda `A`, `L`, `K`, `S`, `0`, model adi ya da acik numara listesi kabul edilir. `A` katalogdaki tum modelleri, `L` kurulu sistemde bulunan katalog modellerini, `K` paket kaynaginda bulunan katalog modellerini secer. Bos Enter ve kisaltmalar reddedilir. `1,2,3` yalniz belirtilenleri; `-4,7,9` ise belirtilenler disindaki butun secenekleri secer. Bilesenler birbirinden bagimsiz sorulur.
`winget` zorunlu degildir. Bulunursa Python disindaki resmi paket kimlikleriyle sessiz kurulum icin kullanilir. Bulunmazsa veya basarisiz olursa Winlama yalniz yapilandirmada sabitlenmis HTTPS adresini, SHA-256 ozetini ve gerekiyorsa Authenticode yayincisini dogrulayarak resmi kurucuya gecer. Uyumlu harici x64 Python `3.11` veya `3.12` varsa kurulum yapmadan kullanilir ve Winlama tarafindan sahiplenilmez. Yoksa Python `3.11.9`, yalniz `%LOCALAPPDATA%\Programs\Winlama\Dependencies\Python311` hedefine, PATH veya Python Launcher kaydi eklemeden kurulur. Kurucu ayrintili gunluk uretir; `1603` ayni hedefle tekrar tekrar denenmez.
Cevrimici kurulum `Runtime` veya `Models` olmadan desteklenir ancak tam 36 dosyalik operasyonel agac zorunludur. Bu agac; 8 kok giris dosyasi, 2 yapilandirma ve 2 workflow JSON dosyasi, 14 motor modulu, varsayilan workflow'un Python/JavaScript/lisans dosyalari, dashboard sablonu, yerellestirme modulu, 3 UI dosyasi, TTS sunucusu ve `String\tr.ini` dosyasindan olusur. Bunlardan biri eksikse paket koku kurulum baslamadan reddedilir; yalniz `.ps1` dosyalari kesinlikle yeterli degildir.
`Online`, ilgili kaynak grubunda dogrudan sabitlenmis resmi adresleri kullanir. `Automatic`, her kurucu veya model grubunda yalniz exact kimligi tam olan yerel kumesi kullanir; grup kismi, eksik veya bozuksa o grubun tamami resmi cevrimici kaynaga gecer. `Local` aga gecmez ve cevrimici yedek kullanmaz; secilen bilesen icin gereken `Runtime` veya `Models` icerigi eksikse kurulum baslamadan acik hatayla durur. Temiz makinede Open WebUI ve Voice icin dogrulanmis cevrimdisi payload tanimi olmadigindan bu iki secim internet ister. NVIDIA surucusu Winlama tarafindan kurulmadigi icin ComfyUI secilecek temiz makinede onceden hazir olmalidir.
Tam 36 dosyalik agac mevcutsa `%LOCALAPPDATA%\Programs\Winlama` gecerli bir paket kokudur. Devam kurulumunda kayitli harici kaynak kullanilamiyorsa calisan `Install.ps1` dosyasinin koku dogrulanip yedek kaynak olarak kullanilir; tam yerel agac mevcutken USB zorunlu degildir. Bununla birlikte `Local` olarak kaydedilmis bir kaynak politikasi, gereken `Runtime` veya `Models` icerigini ayni kokte yine zorunlu tutar. Hizli denetimde kurulu bulunan bilesenlerle modeller icin secim sorusu atlanir; butun sorulardan sonra exact kimlik yeniden dogrulanir ve yalniz eksik islemler calistirilir.
Kurucu, makine duzeyindeki bagimliliklar ve kalici `netsh` guvenlik duvari kurallari icin gerektiginde yonetici izni ister. Kurallar kurulum sirasinda bir kez uygulanir; `Start.ps1`, `Launcher.ps1`, `ModelManager.ps1` ve servis baslaticilari normal kullanici olarak calisir.
Kurulum, tam onarim veya kaldirma yonetici izni gerektirdiginde yukseltme Launcher tarafindan yapilir. Izin reddedilirse mevcut menu kapanmaz ve hata ayrintisi ekranda tutulur. Izin verilirse normal Launcher oturumu kapanir ve tek bir yonetici Launcher penceresi acilir. Kurulum, onarim veya iptal edilen kaldirma sonrasi ayni pencerede ana menuye donulur. Basarili tam kaldirma, kurulum kokundeki dosya kilitlerini birakmak icin Launcher'i kapatir. `Repair.ps1 -SkipInstaller` ile salt dosya/model onarimi dogrudan normal kullanici olarak da calistirilabilir. Alt menulerdeki `Cikis` yalniz bir ust Launcher duzeyine doner; ana Launcher'daki `Cikis` pencereyi kapatir.
Kurulum sonunda gorunur Launcher konsolunda `Start.ps1` saglik denetimi calisir ve eksikse kullanici Startup klasorune `Winlama.lnk` ekler. Kisayol ve servis baslatma yonetici izni istemez. Yeni bir `SYSTEM` zamanlanmis gorevi olusturulmaz; eski surumlerde kalmis `Winlama-Deployment-Resume` gorevi temizlenir. Ollama yalniz resmi `ollama app.exe --hide --fast-startup` tepsi uygulamasiyla, Open WebUI kendi `open-webui.exe serve` komutuyla, ComfyUI ise `run_nvidia_gpu_fast_fp16_accumulation.bat` ile baslatilir. Winlama ayri bir `ollama.exe serve` sureci olusturmaz. Open WebUI ve ComfyUI gorunur konsola baglanir; servis ciktisi renk bilgisini kaybeden bir boruya yonlendirilmez. Normal `Start.ps1` denetiminde konsol Ctrl+C ile kapatildiginda bu oturumun baslattigi surecler de durdurulur. Varsayilan davranis mevcut Ollama'yi korur, Open WebUI/TTS/ComfyUI sureclerini yeniden baslatir. Her servis `-OllamaMode`, `-OpenWebUIMode`, `-VoiceMode` ve `-ComfyUIMode` bagimsiz argumanlariyla `Keep`, `Restart` veya `Skip` moduna alinabilir. Bir servisin hatasi sonraki servislerin denenmesini engellemez; etkin bilesenlerin saglik denetimi tamamlanmadan baslangic basarili sayilmaz. Sonraki oturum acilislarinda servisler su sirayla baslar:
1. Ollama
2. Open WebUI
3. Yerel TTS koprusu
4. Secildiyse ComfyUI
Tarayici otomatik acilmaz.
PowerShell betikleri yorumlanan surecler oldugu icin Gorev Yoneticisi'ndeki surec adi guvenilir bicimde ozellestirilemez. Winlama ek bir calistirici veya gereksiz ikili dosya uretmez; calisan bilesen gorev cubugu ve konsol basliginda `Winlama - Kurulum`, `Winlama - Servisler` veya `Winlama - ComfyUI` olarak gosterilir.
Tum konsol yuzeyleri siyah arka plan ve beyaz temel metin kullanir. Baslayan adimlar camgobegi, basarilar yesil, uyarilar sari, hatalar kirmizi, atlanan islemler mor ve teknik ayrintilar gri gosterilir. Butun girisler ayni satirdaki `| Seçiminiz: ` istemini kullanir; menu satirlarinda `|` karakterinden sonra tam bir bosluk bulunur. Launcher alt betikleri ayni konsola bagli baslatir; cikti boruya veya ayri arka plan penceresine yonlendirilmedigi icin renk bilgisi korunur.
## Resmi tedarik zinciri
Winlama ucuncu taraf ayna veya dosya paylasim sitesi kullanmaz:
| Bilesen | Kaynak |
|---|---|
| PowerShell `7.6.3` | [Microsoft PowerShell GitHub surumu](https://github.com/PowerShell/PowerShell/releases/tag/v7.6.3) |
| Visual C++ Runtime | [Microsoft Download](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist) |
| Python `3.11.9` | [Python Software Foundation](https://www.python.org/downloads/release/python-3119/) |
| Ollama `0.32.5` | [Ollama GitHub surumu](https://github.com/ollama/ollama/releases/tag/v0.32.5) |
| Open WebUI `0.11.0` | [Resmi PyPI paketi](https://pypi.org/project/open-webui/0.11.0/) |
| ComfyUI `0.32.0` | [Comfy-Org GitHub surumu](https://github.com/Comfy-Org/ComfyUI/releases/tag/v0.32.0) |
| FLUX.1-schnell FP8 | [Comfy-Org sabit HF revizyonu](https://huggingface.co/Comfy-Org/flux1-schnell/tree/0cb207e7e753453ef479ae266caf7c1ab364e363) |
| Wan2.1 1.3B | [Wan-AI sabit HF revizyonu](https://huggingface.co/Wan-AI/Wan2.1-T2V-1.3B/tree/37ec512624d61f7aa208f7ea8140a131f93afc9a) |
Kurucu dosyalari sabit surum, resmi HTTPS adresi ve SHA-256 ile tanimlanir. Python ve Visual C++ dosyalarinda beklenen yayinci imzasi da dogrulanir. Open WebUI yalniz `https://pypi.org/simple` dizininden sabit ana surumle kurulur; PyPI gecisli bagimliliklari ayri bir hash-lock veya wheelhouse saglanmadikca tamamen tekrarlanabilir cevrimdisi kurulum sayilmaz. ComfyUI model dosyalari herkese acik resmi depolardan, sabit commit ve SHA-256 ile alinir. Erisim kisitli bir model veya basarisiz bir istege bagli ComfyUI indirmesi, yalniz istege bagli hatalarda devam etme secildiyse ilgili model acik uyariyla atlanarak ana kurulumun surmesini saglar; aksi halde kurulum hata ile durur.
ComfyUI gorsel/video model adiminda secilmezse indirilmez, etkinlestirilmez ve baslangicta calistirilmaz. Secilirse kurucu sirasiyla mevcut kurulum yolunu ve cekirdek kimligi dogrulanan tam `Runtime\ComfyUI` klasorunu kullanir. Bu iki klasor de gecersizse sabitlenmis resmi Comfy-Org `0.32.0` GitHub paketi gecici dizine indirilir, SHA-256 ile dogrulanir, acilir ve gecici paket silinir. Dagitim ortaminda kalici sikistirilmis ComfyUI paketi veya eski ic ice runtime yapisi tutulmaz. Gecerli yerel klasor bulundugunda ag istegi yapilmaz. Ag, indirme, dogrulama veya acma hatasinda ComfyUI yalniz istege bagli hatalarda devam etme secildiyse acik uyariyla atlanir; aksi halde kurulum hata ile durur. Devam eden veya onarim kurulumlarinda da secili ComfyUI modellerinin zorunlu varliklari yeniden dogrulanir.
Secilen Ollama modeli icin `Models` altinda tasinabilir paket varsa manifest, boyut ve blob SHA-256 degerleri ice aktarma sirasinda dogrulanir ve soru sormadan aga tercih edilir. `Automatic` kaynakta gecersiz veya eksik yerel model kumesi resmi `ollama pull` yoluna gecer. Acik `Local` kaynakta ise ag yedegi denenmez ve eksik veya gecersiz paket fail-closed hatasiyla kurulumu durdurur. Varsayilan `qwen3.5:4b` modeli de ayni dogrulama zincirinden gecer. Ollama atlanirsa bagimlilik, calisma zamani, model indirme ve GPU cikarim testleri de tutarli bicimde atlanir; Open WebUI ve ComfyUI secimleri bagimsiz kalir.
## Guvenlik varsayilanlari
- Open WebUI kimlik dogrulamasi zorunludur.
- Ilk hesap yonetici olur; sonraki hesaplar yonetici onayi bekleyen `pending` roluyle acilir.
- OpenAI API passthrough, dogrudan tarayici baglantilari, kullanici API anahtarlari ve topluluk paylasimi kapalidir.
- Varsayilan kullanici izinleri en dusuk yetki yaklasimiyla sinirlandirilmistir.
- Web aramasi DuckDuckGo ile aciktir; sorgular bu harici hizmete gonderilir.
- Open WebUI yalniz yerel alt aga acilir; Ollama'nin olasi `::` dinleyicisi guvenlik duvariyla dis baglantilara kapatilir.
- Kaynak yapilandirmada parola, erisim anahtari veya kullaniciya ozgu bilgi tutulmaz.
Open WebUI ilk kayittan sonra kayit ekranini guvenlik amaciyla kapatir. LAN disindan erisim gerekiyorsa uygulamayi dogrudan yonlendiriciye acmayin; TLS, guvenilir reverse proxy ve uygun kimlik saglayicisi kullanin. Ayrintilar icin [Open WebUI hardening rehberine](https://docs.openwebui.com/getting-started/advanced-topics/hardening/) bakin.
## Open WebUI yapilandirmasi
Kaynak ayarlar [Data/Configs/openui-config.json](Data/Configs/openui-config.json) icindedir. Dosya Open WebUI'in ice aktarilabilir duz anahtar/deger bicimindedir. Kurulum, kullanici izinlerini koruyup su calisma ayarlarini kesinlestirir:
- Varsayilan ve sabitlenmis model: `qwen3.5:4b`
- STT: yerel Whisper `base`
- TTS: yerel OpenAI-uyumlu kopru ve kurulumda secilen `facebook/mms-tts-tur` veya `facebook/mms-tts-eng`
- Web aramasi: DuckDuckGo
- Gorsel uretimi: ComfyUI ve FLUX.1-schnell FP8 API workflow'u
- Gorsel duzenleme: dogrulanmis bir edit workflow'u olmadigi icin kapali
Yapilandirma degistiginde SHA-256 kimligi degisir ve guvenli ice aktarma yeniden uygulanir. Gizli degerler bu dosyaya eklenmemelidir.
Whisper `base` agirliklari Open WebUI tarafindan ilk STT kullaniminda alinabilir; Winlama bu ucuncu taraf donusturulmus agirliklarin revizyonunu veya SHA-256 degerini henuz sabitlemez. Secilen Turkce veya Ingilizce TTS modeli sabit Hugging Face revizyonuyla baslangicta yuklenir ve model/revizyon saglik yaniti dogrulanmadan hazir sayilmaz. Tam cevrimdisi ilk kullanim icin ilgili Open WebUI Python bagimliliklari, Whisper onbellegi ve TTS onbellegi onceden hazirlanmalidir.
## ComfyUI ve workflow yapisi
Wan workflow'unun kanonik calisma yolu:
```text
%LOCALAPPDATA%\Programs\ComfyUI\ComfyUI\user\default\workflows\Wan2.1_T2V_Workflow.json
```
`default_graph.json` ve `default_workflow.json`, guncel ComfyUI on yuzunun varsayilan acilis davranisi icin guvenilir kanonik dosyalar degildir. Winlama workflow'u `workflows` altina yazar. Sorgu veya workflow kimligi icermeyen normal kok acilisinda Wan workflow'unu yukleyen kucuk on yuz modulu [Modules/ComfyUI/DefaultWorkflow](Modules/ComfyUI/DefaultWorkflow) altindadir. Acik bir URL ile secilen workflow'lara dokunulmaz.
Onceki `Data/ComfyUI/Winlama-Default-Workflow` ve `Integrations` yollari kaldirilmistir. ComfyUI modulu artik diger uygulama modulleriyle birlikte `Modules/ComfyUI` altindadir. `Data` yalnizca kaynak yapilandirmalari ve workflow belgelerini icerir.
ComfyUI'in resmi hizli NVIDIA batch dosyasi calisma aninda ek Winlama argumanlarini kabul edecek bicimde hazirlanir ve `--fast fp16_accumulation --reserve-vram 1` ile calisir. Model yollari ComfyUI'in otomatik yukledigi `ComfyUI\extra_model_paths.yaml` dosyasina yazilir; bu uretilen dosya kaynak depoya eklenmez.
Gorsel, video ve Ollama modelleri `Models\<aile>\<varyant>` semasini kullanir. Standart ornekler:
```text
Models/
+-- FLUX.1/schnell/checkpoints/
+-- Wan2.1/1.3B/
+-- qwen3.5/4b/
```
Katalogdaki zorunlu dosyalardan yalniz eksik veya SHA-256 degeri hatali olanlar tamamlanir. Open WebUI gorsel workflow'u `flux1-schnell-fp8.safetensors` checkpoint dosyasini 4 adim ve CFG 1 ile kullanir. Varsayilan Wan workflow'u `Wan2.1_T2V_1.3B.safetensors`, `models_t5_umt5-xxl-enc-bf16.pth` ve `Wan2.1_VAE.pth` dosyalarini kullanir.
Model indirme adresleri yapilandirmadaki resmi yayinci izin listesine uymak zorundadir. Yalniz `Wan-AI` ve ComfyUI'nin `Comfy-Org` Hugging Face kuruluslari izinlidir. Erisim onayi veya kullanici token'i gerektiren FLUX.1-dev otomatik katalogdan cikarilmistir; varsayilan gorsel modeli herkese acik, Apache-2.0 lisansli resmi Comfy-Org FLUX.1-schnell paketidir. Butun model URL'leri degismez yayin commitlerine ve SHA-256 ozetlerine sabitlenmistir. Ollama modelleri yalniz [resmi Ollama kitapligindaki](https://ollama.com/library) etiketlerle yonetilir. Resmi ComfyUI tasinabilir dagitiminin istege bagli ornek sablonlari topluluk baglantilari icerebilir; bunlar Winlama katalogunun parcasi degildir ve Winlama tarafindan otomatik indirilmez.
Katalog varligi bulunan modellerde yalniz tanimli varliklar kopyalanir; ayni varyant klasorundeki arsiv veya kullanici dosyalari korunur. Katalog disi yerel modeller aile/varyant klasoru uzerinden kesfedilir ancak resmi beklenen SHA-256 degeri bilinmeyen serbest dosyalar otomatik onarimda guvenilir kaynak sayilmaz, kopyalanmaz veya indirilmez. ComfyUI'in modeli dogru sinifta gorebilmesi icin varyant icinde `checkpoints`, `diffusion_models`, `unet`, `text_encoders`, `clip`, `clip_vision`, `vae`, `loras` veya `controlnet` alt yollarindan uygun olani kullanilmalidir.
Yerel paket kullanimi ag indirmesini kaldirir ancak ilk kurulumda `Runtime\ComfyUI` ve secilen model dosyalarinin hedef diske fiziksel kopyasi surer. Kurulum suresi kaynak ve hedef depolama hizina baglidir; yarim kalan kopyalar sonraki calistirmada SHA-256 denetimiyle tamamlanir.
## Gecici medya ve raporlar
ComfyUI giris, cikis ve gecici medya dosyalari `%TEMP%\Winlama\ComfyUI` altinda tutulur ve baslangicta temizlenir. Open WebUI ses/gorsel uretim onbellekleri de baslangicta temizlenir. Kalici tutulacak medya ayrica kaydedilmelidir.
`Logs`, `Reports`, `Runtime`, `Models`, `Temp` ve dagitim durum dosyalari Git'e girmez. Cevrimdisi kurucular ve tasinabilir ucuncu taraf calisma klasorleri yalniz `Runtime` altinda tutulur; ayri bir `Artifacts` klasoru kullanilmaz. Gercek kurulum ve onarim varsayilan olarak dagitim kokunde JSONL `Logs` olusturur. Kaldirma gunlugu, silinecek kokun disinda kalmasi icin `%TEMP%\Winlama-Logs` altina yazilir. Varsayilan kurulum ve onarim `Reports` klasoru veya rehber olusturmaz. HTML raporu yalniz `-GenerateReport` acikca verildiginde yazilir ve klasor de ancak o anda olusturulur. Kurulum, onarim ve rapor zaman damgalari Windows ile uyumlu `yyyy-MM-dd_HH-mm-ss` bicimindedir; ayni saniyedeki sonraki dosyalara `_1`, `_2` eki verilir. Model Manager `model-manager.log`; kaldirma ise benzersiz zaman damgasi ve GUID iceren `uninstall-*.log` adini kullanir. `Runtime/bin` olusturulmaz.
## Yonetim ve kaldirma
- Ana menu: `RunMe.bat`
- Servisleri sirayla baslatma: `Start.ps1`
- Model ve ComfyUI yonetimi: `ModelManager.ps1`
- Cift yonlu SHA denetimi, onarim ve paket yayimlama: `Repair.ps1`
- Secimli tam kaldirma: `Uninstall.ps1`
Tam kaldirmada bilesenler acikca `A` veya numaralarla secilir; bos giris reddedilir. ComfyUI ve modelleri, Open WebUI, Ollama, Ollama modelleri, Winlama Python kutuphaneleri, Winlama Python 3.11 ve gelistirici CLI araclari ayri ayri korunabilir veya kaldirilabilir. Hicbir silme ikinci istemde tam olarak `EVET` yazilmadan baslamaz; `HAYIR` da acikca yazilmalidir.
Python secildiginde yalniz Winlama sahiplik kaydiyla eslesen izole `%LOCALAPPDATA%\Programs\Winlama\Dependencies\Python311` kurulumu kaldirilir; sistemdeki diger Python kurulumlari korunur. Gelistirici CLI temizligi yalniz resmi `@openai/codex`, `@github/copilot`, `GitHub.Copilot`, `GitHub.Copilot.Prerelease` kimliklerini ve Codex'in resmi varsayilan Windows standalone yerlesimini hedefler. Codex kullanici oturumlari, ayarlari, editor eklentileri ve exact kimlikle eslesmeyen diger paketler korunur. Tam kaldirma sonundaki kok-temizlik yardimcisi ayri pencere acmaz; ayni yonetici konsolunda sonucunu gosterir.
Tum etkilesimli betikler islem sonunda renkli bir ozet gosterir. Oturum ancak tam olarak `CIKIS`, Launcher alt menusune donus ise tam olarak `DEVAM` yazildiginda ilerler. Bos Enter, kisaltilmis onaylar ve gecersiz girisler hicbir eylem baslatmaz.
Onceki Winlama surumu kurulmussa Open WebUI ve Ollama verilerini silmek gerekmez. Onarim merkezi belirli bir depolama turune ozel degildir; baska bir disk, bolum, ag konumu veya ayni diskteki farkli bir `Winlama` klasoru paket hedefi olabilir. Uc calisma modu vardir:
1. `Iki tarafi onar`: Secilen paketi kanonik uygulama kaynagi kabul eder; betik, modul, servis, yerellestirme ve workflow dosyalarini kurulu hedefe uygular. Modeller paket ile kurulu/yerel hedef arasinda iki yonlu olarak dogrulanir; yalniz bir tarafta saglam olan varlik diger tarafa tamamlanir. Kurulu hedefteki bilinmeyen veya kullanici tarafindan degistirilmis ek dosyalar silinmez ve cozulmemis fark olarak raporlanir. Ardindan kurulu hedefin etkin yapilandirmasiyla etkilesimsiz `Install.ps1 -Resume -ForceRepair` saglik akisi calistirilir.
2. `Paketten kurulu sisteme onar`: Paket icerigini kaynak kabul eder, kurulu uygulama ve modelleri dogrulanmis dosyalarla gunceller ve `Install.ps1 -ForceRepair` saglik akisini calistirir.
3. `Kaynak paketi kurulu/yerel hedeften onar`: Uygulama dosyalarini secilen `Winlama` paket hedefine esitler ve kurulu sistemde dogrulanmis model varliklariyla paketi gunceller. Hedefteki `Models` ve `Runtime` fazlaliklari silinmez.
Onarim bittikten sonra ayni kapsam salt okunur olarak yeniden denetlenir. Yalniz cozulmemis fark, atlanan islem ve teknik hata sifirsa sonuc basarili olur; aksi halde konsol sonucu `Tamamlanmadi` veya `Basarisiz` olarak gosterir. HTML raporu yalniz `Repair.ps1 -GenerateReport` acikca verildiginde yazilir.
## Kaynak dogrulama
Kurulum yapmadan kaynak butunlugunu denetlemek icin:
```powershell
powershell.exe -NoProfile -File .\Install.ps1 -ValidateOnly -NoPause -Verbose
```
Tum `.ps1` giris noktalari `-ValidateOnly -Verbose` destekler. Bu mod yonetici izni istemez, servis baslatmaz, dosya kopyalamaz veya silmez ve `Logs`/`Reports` olusturmaz. Gercek bir paketle yalniz farklari gormek icin `Repair.ps1` calistirilip uygulama sorusuna `HAYIR`; onarim icin `EVET` yaniti verilir.
Kurulum, baslatma, onarim, model aktarimi ve kaldirma gibi kritik islemler JSONL gunluklerine yazilir. Kurulum veya onarim raporu istenirse ilgili betige `-GenerateReport` acikca verilir; varsayilan akista HTML ve `Reports` klasoru uretilmez.
`Install.ps1 -ValidateOnly -Verbose`; Launcher, Engine, Start, Model Manager, Repair, Uninstall, Open WebUI ve ComfyUI dogrulayicilarini ayri PowerShell sureclerinde calistirir. Sonuc yalniz surec cikis koduyla degerlendirilmez; PowerShell `ErrorRecord` nesneleri, standart hata, kritik cikti desenleri, her betigin benzersiz tamamlanma isareti ve yeni `Logs`/`Reports` olusturulup olusturulmadigi birlikte denetlenir. Kurulum bileseni, Ollama modeli, ComfyUI modeli, ana menu ve alt menu yuzeyleri gercek cizim islevleriyle olusturulur; numara, sira, benzersizlik, renk dizisi ve istem sozlesmeleri de dogrulanir. Yakalanip guvenli bir geri donus degerine cevrilen istisnalarin nedeni `-Verbose` ciktisinda korunur.
`-ValidateOnly`; PowerShell sozdizimini, yapilandirma sozlesmelerini, yerellestirmeyi, resmi kaynak izin listesini, sessiz kurulum argumanlarini, workflow eslemelerini ve metin dosyasi politikasini denetler. Gizli test klasorleri ile `Runtime`, `Models`, `Logs` ve `Reports` kaynak kod sanilarak taranmaz. Bu denetim gercek bir Windows kurulumu degildir. Yayin kabulu icin sifir Windows 11 sanal makine snapshot'inda `RunMe.bat` uzerinden cevrimici kurulum; dogrulanmis `Local` payload bulunan ve internet istemeyen bilesenlerle cevrimdisi kurulum; ardindan varsayilan tam kaldirma ve yeniden kurulum ayrica denenmelidir.
ComfyUI paket ve model durumunu yonetici izni olmadan listelemek icin:
```powershell
powershell.exe -NoProfile -File .\ModelManager.ps1 -Action ComfyUIList -NoPause
```
## Proje yapisi
```text
Winlama/
+-- Data/
|   +-- Configs/
|   +-- Workflows/
+-- Modules/
|   +-- ComfyUI/
|       +-- DefaultWorkflow/
+-- Services/
+-- String/
+-- Engine.ps1
+-- Install.ps1
+-- Launcher.ps1
+-- ModelManager.ps1
+-- Repair.ps1
+-- RunMe.bat
+-- Start.ps1
+-- Uninstall.ps1
```
## Lisanslar
Winlama kaynak kodu [MIT lisansi](LICENSE) altindadir. ComfyUI ile ayni surecte calisan [varsayilan workflow modulu](Modules/ComfyUI/DefaultWorkflow/LICENSE) GPL-3.0-only olarak ayrica lisanslanmistir. Harici uygulamalar ve model agirliklari kendi lisanslarina tabidir:
- [Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B): Apache-2.0
- [Wan2.1-T2V-1.3B](https://huggingface.co/Wan-AI/Wan2.1-T2V-1.3B): Apache-2.0
- [Whisper](https://github.com/openai/whisper/blob/main/LICENSE): MIT
- [ComfyUI](https://github.com/Comfy-Org/ComfyUI): GPL-3.0
- [Comfy-Org FLUX.1-schnell](https://huggingface.co/Comfy-Org/flux1-schnell): Apache-2.0
- [facebook/mms-tts-tur](https://huggingface.co/facebook/mms-tts-tur): CC-BY-NC-4.0
- [facebook/mms-tts-eng](https://huggingface.co/facebook/mms-tts-eng): CC-BY-NC-4.0
- [Open WebUI](https://github.com/open-webui/open-webui/blob/main/LICENSE): Open WebUI License ve marka kosullari
Bu varsayilan paket ticari olmayan kullanim hedefler. MMS Turkce ve Ingilizce TTS modelleri CC-BY-NC-4.0 oldugu icin ticari kullanimi sinirlar; FLUX.1-schnell, Wan ve Qwen agirliklari ise listelenen Apache-2.0 kosullarina tabidir. Model ciktilarinin kullanim kosullari model lisansinin tamamindan ayrica dogrulanmalidir. Bu ozet hukuki danismanlik degildir.