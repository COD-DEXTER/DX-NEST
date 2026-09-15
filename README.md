# DX-NEST — Free VPS Manager روی Daytona

بازطراحی کامل پروژه `DAYTONA-VPS1`. این نسخه یک **VM Manager واقعی** است، نه یک اسکریپت یک‌بار-اجرا برای بالا آوردن QEMU.

## ۰. نصب و استفاده روزمره

### نصب

```bash
bash <(curl -sSL https://raw.githubusercontent.com/COD-DEXTER/DX-NEST/main/install.sh)
```

این installer:

1. خودش را در مسیر پایدار `/usr/local/lib/dx-nest/install.sh` نصب می‌کند.
2. دستور `dx` را در `/usr/local/bin/dx` می‌سازد.
3. منوی اصلی DX-NEST را باز می‌کند (یا اگر آرگومان CLI داده شده، همان را اجرا می‌کند).

نصب **idempotent** است: اگر VM/دیسک/config از قبل وجود داشته باشد، اجرای دوباره‌ی installer هرگز آن‌ها را حذف یا بازسازی نمی‌کند — فقط خودِ manager script و دستور `dx` را (دوباره) نصب می‌کند.

### اگر GitHub در این شبکه block باشد

از `bootstrap.sh` استفاده کن — چند source را امتحان می‌کند و قبل از اجرا، دانلود را validate می‌کند (`bash -n`):

```bash
bash <(curl -sSL https://raw.githubusercontent.com/COD-DEXTER/DX-NEST/main/bootstrap.sh)
```

یا source خودت را بده (فقط HTTPS پذیرفته می‌شود):

```bash
DXNEST_INSTALL_URL="https://your-mirror.example.com/install.sh" \
  bash <(curl -sSL https://raw.githubusercontent.com/COD-DEXTER/DX-NEST/main/bootstrap.sh)
```

اگر همه source‌ها (شامل GitHub و fallback CDN) fail شوند، bootstrap هرگز یک source ناشناخته/validate‌نشده را اجرا نمی‌کند — با `[ERROR]` و دلیل واضح (DNS/timeout/TLS/…) متوقف می‌شود.

### استفاده روزمره

```bash
sudo su
dx
```

`dx` از هر directory کار می‌کند، به هیچ session یا terminal قبلی وابسته نیست، و بعد از نصب اولیه **به اینترنت نیاز ندارد** (فقط دانلود اولیه‌ی Ubuntu image و نصب dependency به اینترنت نیاز دارند — خودِ منو و `dx status`/`dx enter` نه).

### CLI

```bash
dx status
dx start
dx stop
dx restart
dx enter
dx logs
dx console
dx network
dx config
dx install    # (Re)install/repair the persistent dx command — بدون دانلود، بدون تغییر VM
dx help
```

خروجی: `0` = موفق، غیر-صفر = شکست (مناسب برای استفاده در اسکریپت).

اگر `dx` هم به هر دلیلی پاک شد، خودِ manager موجود می‌تواند آن را دوباره بسازد: از منو **Maintenance → Repair/verify 'dx' command** یا مستقیم:

```bash
/usr/local/lib/dx-nest/install.sh install
```

## ۱. یافته‌های تحقیق روی مستندات فعلی Daytona

این‌ها را مستقیماً از مستندات رسمی (daytona.io/docs) تأیید کردم، نه از حافظه:

- **Snapshot ≠ Image شما.** `daytona-large` یکی از Snapshotهای پیش‌فرض Daytona است (۴ vCPU / ۸GiB RAM / ۱۰GiB Disk، بر پایه ایمیج `daytonaio/sandbox`) و صرفاً یک **Container Sandbox** می‌سازد. عدد ۳۲GB RAM / ۸ CPU که شما داری، مقدار override‌شده‌ی خودِ Sandbox است (Daytona اجازه‌ی تنظیم resources سفارشی تا سقف tier سازمانت را می‌دهد)، نه ویژگی خودِ `daytona-large`.
- **Sandbox Class مهم است.** Daytona سه کلاس Sandbox دارد: Container، VM (Linux VM / Windows)، GPU. فقط کلاس VM قابلیت‌های `pause/resume` و `auto-pause` واقعی Daytona را دارد. Sandbox شما (از snapshot عادی مثل daytona-large) از نوع **Container** است — یعنی auto-pause خودِ Daytona اصلاً برایش اعمال نمی‌شود؛ چیزی که شما "VM" می‌نامید (Ubuntu روی QEMU) یک لایه‌ی نرم‌افزاری داخل همین Container است، برای Daytona ناشناخته و نامرئی.
- **Persistence:** طبق مستندات، Container Sandboxها به‌صورت پیش‌فرض persistent هستند: `stop` فقط حافظه/پردازش‌ها را پاک می‌کند، فایل‌سیستم (یعنی qcow2 و seed.img شما روی دیسک) دست‌نخورده می‌ماند تا وقتی خودت sandbox را `delete` کنی یا Ephemeral/Auto-delete را فعال کرده باشی. این یعنی معماری فعلی شما (نگه‌داشتن qcow2 روی دیسک) از پایه درست بوده؛ مشکل فقط در اسکریپت مدیریت آن بود.
- **Lifecycle سه‌گانه:** Auto-stop (پیش‌فرض ۱۵ دقیقه بی‌کاری)، Auto-archive (پیش‌فرض ۷ روز پس از stop، حداکثر قابل تنظیم ۳۰ روز)، Auto-delete (پیش‌فرض غیرفعال). فعالیت‌هایی مثل SSH session یا ترافیک Preview تایمر auto-stop را ریست می‌کنند؛ پردازشی که فقط *داخل* Sandbox در حال اجراست (مثل QEMU شما) به‌تنهایی شمرده نمی‌شود.
- **نتیجه عملی برای تنظیمات Daytona شما:**
  - `Ephemeral = OFF` ✅ درست بود، نگه دار.
  - `Auto-delete = Disabled` ✅ درست بود، نگه دار.
  - `Auto-stop`: بهتر است روی `0` (غیرفعال) بگذاری تا Sandbox صرفاً به‌خاطر بی‌کاری در سطح Daytona متوقف نشود و QEMU وسط کار قطع نشود؛ یا اگر می‌خواهی صرفه‌جویی هزینه داشته باشی، `refresh_activity` را طبق مستندات به‌صورت دوره‌ای صدا بزن. عدد ۴۳۸۰۰ دقیقه‌ی فعلی هم کار می‌کند ولی صرفاً یک عدد بزرگ دلخواه است، نه یک مکانیزم رسمی متفاوت.
  - `Auto-archive = 10080` (۷ روز) همان پیش‌فرض است؛ چون Sandbox شما Container است (نه VM class)، archive یعنی انتقال فایل‌سیستم کامل به cold storage و بازگرداندنش هنگام start — برای qcow2 چند-گیگابایتی شما قابل قبول است، فقط انتظار نداشته باش "resume آنی" مثل VM-class داشته باشی.
  - **Network:** `Block All Network Access = OFF` نگه دار (برای apt/wget لازم است). اگر خواستی محدودتر باشد، از `domain_allow_list` (مثلاً `archive.ubuntu.com,cloud-images.ubuntu.com`) استفاده کن، نه بلاک کامل.
  - **دسترسی به خودِ Sandbox** (نه VM داخلش) باید از طریق SSH Access رسمی Daytona (`daytona ssh <sandbox-id>`, توکن موقت) یا Web Terminal روی پورت `22222` باشد — این دو کاملاً از SSH داخلی VM شما (پورت ۲۲۲۲) جدا هستند.

## ۲. مشکلات نسخه قبلی که برطرف شد

| مشکل | راه‌حل در v2 |
|---|---|
| کاربر cloud-init ناقص، بدون `users:`/`ssh_authorized_keys` | cloud-config کامل: `users:` با sudo NOPASSWD، ورود پیش‌فرض با SSH key اختصاصی (تولید خودکار)، پسورد اختیاری |
| `chmod 666` روی qcow2 | `chmod 600`، مالکیت کاربر اجراکننده |
| Resize دیسک تکراری | فقط یک‌بار در create، با فایل نشانه‌گذار `.disk_size_gb`؛ رشد بعدی فقط از منوی صریح "Grow disk" |
| Restart بدون چک اینکه QEMU از قبل زنده است → Disk lock | `is_vm_running()` قبل از هر start؛ `flock` روی عملیات start/stop برای idempotency |
| QEMU با `-nographic` ترمینال منو را می‌قاپید | `-display none` + `-daemonize -pidfile` + کنسول/مانیتور روی UNIX socket جدا |
| بدون PID/Log management | `-pidfile` بومی QEMU + `logs/vm-boot.log` + `logs/dxnest.log` |
| بدون Health Check برای SSH | `wait_for_ssh` با پولینگ TCP + گرفتن بنر SSH، تا ۹۰ ثانیه |
| بدون گزینه "Enter VM" | منوی [۵] Enter VPS: اگر خاموش بود روشن می‌کند، صبر می‌کند تا SSH آماده شود، بعد وارد می‌شود |
| `pkill sh` / `rm -rf` بدون تأیید | حذف کامل؛ Stop فقط با سیگنال به PID دقیق (بعد از تطبیق cmdline)؛ Reset کامل فقط با تایپ `DELETE` |
| وابستگی اجباری به sshx.io (`curl \| sh`) | حذف کامل؛ دسترسی فقط از طریق پورت لوکال + SSH Access رسمی Daytona برای خودِ Sandbox |
| RAM/CPU برابر کل منابع Sandbox | فیلد جدید "Sandbox RAM/CPU" در VPS Config برای چک ایمنی؛ هشدار اگر VM چیزی برای host نگذارد |
| خطاهای apt مخفی (`>/dev/null 2>&1`) | خروجی واقعی apt نمایش داده می‌شود؛ `set -Eeuo pipefail` + trap روی خطا |
| مسیرهای relative | همه چیز زیر `BASE_DIR=/home/daytona/dxnest` (قابل override با `DXNEST_HOME`) |
| نسخه ایمیج pin نشده | دانلود «current» + تأیید یکپارچگی با SHA256SUMS رسمی کانونیکال (محدودیت: پین دقیق تاریخی نیاز به Snapshot گرفتن دستی دارد، که در بخش بعد توضیح داده شده) |

## ۳. معماری جدید

```
Daytona Sandbox (Container class, e.g. daytona-large + custom resources)
└── /home/daytona/dxnest/          (BASE_DIR)
    ├── install.sh                 (این فایل — DX-NEST manager)
    ├── config.env                 (RAM/CPU/Disk/Port — بدون کردنشیال hardcode، فقط keyهای whitelist‌شده)
    ├── ubuntu-22.04-base.qcow2     (ساخته و resize فقط یک‌بار)
    ├── seed.img / user-data       (cloud-init — فقط با تغییر صریح بازسازی می‌شود)
    ├── dxnest_ed25519(.pub)       (کلید SSH اختصاصی VM)
    ├── ssh/known_hosts            (known_hosts اختصاصی DX-NEST — هرگز ~/.ssh کاربر را لمس نمی‌کند)
    ├── vm.pid                     (نوشته‌شده توسط خودِ QEMU با -pidfile)
    ├── .disk_size_gb              (نشانه‌گذار سایز دیسک — با سایز واقعی qcow2 تطبیق داده می‌شود)
    ├── .accel_mode                (KVM یا TCG — همانی که آخرین بار واقعاً استفاده شد)
    ├── qemu-monitor.sock          (برای system_powerdown درست)
    ├── qemu-console.sock          (کنسول سریال، بدون قاپیدن ترمینال منو)
    └── logs/
        ├── vm-boot.log            (rotate خودکار بعد از ۲ مگابایت)
        └── dxnest.log             (rotate خودکار بعد از ۲ مگابایت)
```

### ۳.۱ لایه‌های Lifecycle — کاملاً مجزا

```
Daytona Sandbox lifecycle   (start/stop/pause/archive/delete — کنترل Daytona)
        ≠
DX-NEST lifecycle           (این اسکریپت: config, disk, seed, لاگ‌ها)
        ≠
QEMU process lifecycle      (start_vm / stop_vm / restart_vm در این منو)
        ≠
Ubuntu Guest lifecycle      (بوت/sshd/cloud-init داخل خودِ مهمان)
```

اگر خودِ Sandbox متوقف، pause یا حذف شود، DX-NEST نمی‌تواند آن لایه‌ی بیرونی Daytona را override کند — QEMU هم به‌ناچار همراه آن متوقف می‌شود. DX-NEST فقط سه لایه‌ی پایینی را مدیریت می‌کند.

### ۳.۲ نکته مهم درباره IP عمومی

DX-NEST یک VPS با **IP عمومی واقعی** نمی‌سازد. مسیر واقعی ترافیک این است:

```
Internet → Daytona → Sandbox → QEMU user-mode NAT → Ubuntu Guest
```

پورت `127.0.0.1:${HOST_SSH_PORT}` فقط **داخل همان Sandbox** قابل‌دسترسی است، نه از اینترنت. اگر سرویسی روی Ubuntu Guest نیاز به دسترسی عمومی دارد، باید از مکانیزم رسمی خودِ Daytona (Public Preview URL، Network settings) استفاده شود — DX-NEST این را جایگزین نمی‌کند و در جایی از UI ادعای "Public VPS IP" نمی‌کند.

## ۳.۳ چیزهایی که در نسخه v2.1 (hardening pass) اضافه/اصلاح شد

- بارگذاری امن `config.env`: دیگر با `source` اجرا نمی‌شود؛ فقط پارس خط‌به‌خط روی whitelist مشخص، با validation کامل (بازه RAM/CPU/Disk/Port، regex نام کاربری، enum برای AUTH_MODE).
- `known_hosts` اختصاصی زیر `ssh/` — هیچ‌وقت `~/.ssh/known_hosts` سیستم کاربر را عوض نمی‌کند.
- بررسی `/dev/kvm` قبل از boot؛ Status نشان می‌دهد VM با KVM یا TCG بالا آمده.
- تطبیق نشانه‌گذار سایز دیسک (`.disk_size_gb`) با سایز واقعی qcow2؛ هرگز به‌صورت خودکار shrink نمی‌کند.
- `restart_vm` واقعاً verify می‌کند: stop → تأیید متوقف‌شدن → start → تأیید اجرا → تأیید SSH auth؛ در صورت شکست موفقیت جعلی گزارش نمی‌دهد.
- «Enter VPS» در صورت شکست SSH یک منوی بازیابی واقعی نشان می‌دهد (Retry/Status/Logs/Console/Restart) به‌جای یک warning و خروج.
- منوی SSH/Network حالا diagnostics واقعی دارد: تست پورت host، تست SSH/DNS/Internet مهمان، به‌تفکیک لایه Sandbox در مقابل لایه Guest.
- `AUTH_MODE` و `VM_USER` از داخل «VPS Config» قابل تغییرند (با هشدار درباره VM موجود).
- حالت CLI/غیرتعاملی: `install.sh {status|start|stop|restart|enter|logs|console|network|config|help}` با exit code مناسب برای اسکریپت‌نویسی.
- بررسی هویت PID قوی‌تر (`/proc/<pid>/cmdline` + `/proc/<pid>/exe`) تا reuse شدن یک PID قدیمی اشتباهاً "در حال اجرا" تشخیص داده نشود.
- Log rotation ساده برای هر دو لاگ (پیش‌فرض rotate بعد از ۲ مگابایت، ۳ نسخه قدیمی نگه داشته می‌شود).

## ۴. محدودیت شناخته‌شده

- Snapshot گرفتن از خودِ ایمیج/وضعیت VM (برای reproducibility کامل یا سرعت boot بالاتر) در این نسخه پیاده نشده؛ Daytona برای این کار مکانیزم Cold/Hot Snapshot در سطح خودِ Sandbox دارد، ولی چون VM شما software نسته‌شده (QEMU) است نه یک VM-class Sandbox، آن مکانیزم مستقیماً روی qcow2 داخلی اعمال نمی‌شود. اگر بعداً خواستی، می‌شود بعد از اولین boot موفق، یک Snapshot از خودِ Sandbox (شامل qcow2 آماده) گرفت تا ساخت‌های بعدی از صفر دانلود نکنند.
- KVM ممکن است داخل Sandbox در دسترس نباشد (nested virtualization به تنظیمات Daytona/host بستگی دارد)؛ اسکریپت با `-machine accel=kvm:tcg` این را امتحان می‌کند و در نبود KVM به TCG (نرم‌افزاری، کندتر) سقوط می‌کند — یعنی از کار نمی‌افتد، فقط کندتر بوت می‌شود.
- تشخیص خودکار RAM/CPU واقعی خودِ Sandbox (نه فقط هاستِ زیرینِ Daytona) از داخل یک Container Sandbox قابل‌اعتماد نیست؛ به همین دلیل `Sandbox RAM/CPU` یک مقدار **کاربر-وارد-شده** در VPS Config است، نه auto-detected — وقتی وارد نشده باشد صراحتاً `UNKNOWN` نشان داده می‌شود (نه یک عدد گمراه‌کننده مثل `0G`) و resource-safety check در آن حالت فقط informational است، هرگز false-reject نمی‌کند.

## ۵. تغییرات v2.2 — مشکلات واقعی مشاهده‌شده در Daytona + نصب پایدار `dx`

این فاز روی مشکلاتی متمرکز بود که واقعاً در یک اجرای واقعی روی Daytona دیده شدند، به‌علاوه‌ی نصب پایدار دستور `dx`:

- **باگ واقعی و تأییدشده رفع شد:** `status_vm` زمانی که `qemu-img info` (مثلاً چون qcow2 توسط QEMU در حال اجرا قفل شده) یا `ps` fail می‌شدند، کل منو را کرش می‌کرد — چون این خواندن‌ها به‌صورت `var=$(pipeline)` بدون گارد نوشته شده بودند و زیر `set -Eeuo pipefail`، شکست هر جزء از pipeline باعث خروج کل اسکریپت می‌شد. این دقیقاً همان خطای واقعی مشاهده‌شده (`Unexpected failure at line 470 ... head -n1`) بود. همه‌ی این خواندن‌ها الان با idiom امن (`var=$(...) || var=default`) نوشته شده‌اند و شکستشان فقط `UNKNOWN` نشان می‌دهد، نه کرش. این سناریوی دقیق (هم `qemu-img` و هم `ps` هر دو fail، هم‌زمان) در تست بازتولید و تأیید شد.
- **Sandbox RAM/CPU نامشخص دیگر `0G / 0 vCPU` نشان نمی‌دهد** — صریحاً `UNKNOWN` نشان می‌دهد، و resource-safety check در این حالت هرگز به‌اشتباه VM را reject نمی‌کند.
- **نصب پایدار `dx`:** installer خودش را در `/usr/local/lib/dx-nest/install.sh` کپی می‌کند و `/usr/local/bin/dx` می‌سازد — کاملاً مستقل از BASE_DIR (هرگز VM/دیسک موجود را لمس نمی‌کند)، مستقل از directory اجرا، و مستقل از اینترنت (فقط کپی فایل محلی است).
- **`bootstrap.sh`** اضافه شد: چند source (GitHub + fallback CDN، یا override با `DXNEST_INSTALL_URL`)، فقط HTTPS، و قبل از اجرا `bash -n` روی فایل دانلودشده validate می‌کند — هرگز یک منبع ناشناخته/نامعتبر را اجرا نمی‌کند.
- منوی Maintenance گزینه‌ی **Repair/verify 'dx' command** گرفت (بدون دانلود، بدون تغییر VM) و CLI هم `dx install` را پشتیبانی می‌کند — برای زمانی که `dx` پاک شده ولی نصب DX-NEST سالم است.
- منوی اصلی (`[1]`..`[9]`, `[0]`) دست‌نخورده ماند؛ فقط زیرمنوی Maintenance یک گزینه‌ی جدید گرفت.

## ۷. Public SSH (via Cloudflare) — v2.3.0

### این چیست؟

DX-NEST می‌تواند SSH گست اوبونتو را از طریق **Cloudflare Tunnel** به بیرون expose کند، بدون این‌که هرگز پورت QEMU (`127.0.0.1:2222`) عمومی شود. این یک ماژول کاملاً مستقل است — اگر Cloudflare/cloudflared خراب یا خاموش باشد، `dx status`/`start`/`stop`/`restart`/`enter` بدون هیچ تغییری کار می‌کنند.

```
Cloudflare API Token
        │
        ▼
     DX-NEST
        │
        ├── ساخت/استفاده مجدد از Tunnel
        ├── تنظیم SSH route
        └── دریافت Tunnel Token
                    │
                    ▼
              cloudflared
                    │
                    ▼
             127.0.0.1:2222
                    │
                    ▼
                  QEMU
                    │
                    ▼
              Ubuntu SSH
```

Origin همیشه: `ssh://localhost:2222`

### پیش‌نیازها

- یک اکانت Cloudflare
- یک دامنه/zone که روی Cloudflare مدیریت می‌شود
- یک **Cloudflare API Token** با permission `Account → Cloudflare Tunnel → Edit` (و اختیاری `Zone → DNS → Edit` برای ساخت خودکار رکورد DNS)
- یک hostname برای SSH عمومی (مثل `ssh.example.com`)
- اتصال خروجی از Sandbox به Cloudflare
- VPS در حال اجرا (`dx start`)

### دو credential جدا — هرگز یکی نیستند

| | Cloudflare **API** Token | Cloudflare **Tunnel** Token |
|---|---|---|
| فایل | `remote/cloudflare-api.token` (۰۶۰۰) | `remote/cloudflared.token` (۰۶۰۰) |
| مصرف | فقط برای تماس با `api.cloudflare.com` هنگام Setup/Repair | فقط برای اجرای واقعی `cloudflared` |
| کی گرفته می‌شود | کاربر آن را از داشبورد Cloudflare می‌سازد و paste می‌کند | DX-NEST خودش از API می‌گیرد؛ کاربر هرگز آن را نمی‌بیند |

`cloudflared` هیچ‌وقت با API Token اجرا نمی‌شود.

### مسیر Setup واقعی

```
[10] Public SSH (via Cloudflare)
        ↓
[1] Setup   (یا [6] Open Cloudflare Token Setup برای راهنمای ساخت توکن)
        ↓
ساخت Custom API Token در Cloudflare (Account → Cloudflare Tunnel → Edit)
        ↓
paste کردن API Token در DX-NEST (ورودی مخفی)
        ↓
وارد کردن hostname
        ↓
DX-NEST اکانت را خودکار پیدا می‌کند (یا Account ID را می‌پرسد)
        ↓
DX-NEST یک Tunnel با نام قطعی dx-nest-<hostname> می‌سازد یا اگر از قبل بود، همان را استفاده می‌کند (بدون duplicate)
        ↓
DX-NEST route را تنظیم می‌کند: hostname → ssh://localhost:2222
        ↓
DX-NEST خودش Tunnel Token را از API می‌گیرد
        ↓
تلاش best-effort برای ساخت رکورد DNS (اگر permission کافی نباشد، راهنمای دستی نشان داده می‌شود)
        ↓
cloudflared شروع می‌شود
```

`[6] Open Cloudflare Token Setup` فقط لینک ساده‌ی `https://dash.cloudflare.com/profile/api-tokens` و سه قدم دستی را نشان می‌دهد. **عمداً** یک URL با پارامتر آماده‌ی `permissionGroupKeys=...` نمی‌سازد، چون این پارامتر برای account token توسط خود Cloudflare مستند نشده (یک GitHub issue باز و حل‌نشده در `cloudflare/cloudflare-docs` همین را تأیید می‌کند) — حدس‌زدنش ریسک بیشتری از یک راهنمای متنی ساده دارد.

### اتصال — CLI

```
ssh root@ssh.example.com
```

OpenSSH معمولی به‌تنهایی نمی‌تواند به یک Cloudflare Tunnel hostname وصل شود؛ باید روی دستگاه خودتان (نه روی Sandbox) این را به `~/.ssh/config` اضافه کنید:

```
Host ssh.example.com
    ProxyCommand cloudflared access ssh --hostname %h
```

مسیر واقعی اتصال:

```
OpenSSH → cloudflared access ssh → Cloudflare → Tunnel → cloudflared روی Daytona → 127.0.0.1:2222 → Ubuntu SSH
```

### اتصال — Browser

`https://ssh.example.com` فقط وقتی کار می‌کند که **Cloudflare Access + Browser Rendering: SSH** را خودتان در Zero Trust فعال کرده باشید. DX-NEST هیچ Access Policy‌ای را خودکار نمی‌سازد یا مدیریت نمی‌کند — صرفاً وجود Tunnel به‌تنهایی باعث فعال‌شدن Browser SSH نمی‌شود.

### امنیت

- پورت QEMU (`127.0.0.1:2222`) هرگز عمومی نمی‌شود؛ هیچ تغییری در شبکه QEMU داده نشد.
- هیچ Global API Key، هیچ OAuth، و هیچ credential اضافی جز همان یک API Token لازم نیست.
- هر دو توکن: ورودی مخفی، هرگز echo نمی‌شوند، هرگز در `config.env`/log/status/`dx config` ظاهر نمی‌شوند، دائم با پرمیژن ۰۶۰۰ ذخیره می‌شوند.
- `cloudflared` با `--token-file` اجرا می‌شود (نه `--token`) تا توکن حتی در `ps` هم دیده نشود.
- اگر `AUTH_MODE=password` باشد، Setup قبل از ادامه هشدار می‌دهد و توصیه می‌کند Cloudflare Access را فعال کنید؛ در `AUTH_MODE=key` بدون بلاک ادامه می‌دهد (باز هم توصیه می‌شود).

### Repair و Disable

- **Repair**: اگر فقط Tunnel Token گم شده باشد ولی API Token و Tunnel ID هنوز موجود باشند، خودش دوباره می‌گیرد — بدون نیاز به Setup از اول. Repair هرگز qcow2، کلید SSH گست، شبکه QEMU، یا خود اوبونتو را دست نمی‌زند.
- **Disable**: فقط `cloudflared` را متوقف می‌کند؛ Tunnel/DNS/VM/QEMU دست‌نخورده می‌مانند.

## ۶. تغییرات v2.2.1 — Final Release Audit

- **باگ امنیتی/پایداری واقعی رفع شد:** نصب/بازنصب persistent manager (`self_install`) قبلاً با `cp -f` مستقیم روی `/usr/local/lib/dx-nest/install.sh` می‌نوشت. اگر وسط این کپی مشکلی پیش می‌آمد (دیسک پر، قطع دسترسی، فایل مبدأ نامعتبر)، ممکن بود یک نسخه‌ی نصفه/خراب از manager باقی بماند. الان نصب از الگوی «temp file داخل همان دایرکتوری → `bash -n` validation → `mv` atomic» استفاده می‌کند؛ یعنی یا نصب کامل و سالم انجام می‌شود، یا نسخه‌ی قبلی (اگر وجود داشت) دست‌نخورده باقی می‌ماند — هرگز یک باینری نصفه‌نصفه. این دقیقاً با یک تست مستقیم (تزریق فایل نامعتبر به‌جای source واقعی) تأیید شد.
- هیچ تغییر رفتاری دیگری در این نسخه انجام نشد؛ منو، CLI، architecture و مستندات همان v2.2 هستند.
