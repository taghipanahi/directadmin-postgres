# راهنمای نصب پلاگین PostgreSQL Manager روی DirectAdmin 1.697

## این پلاگین چه کار می‌کند؟

- هر کاربر DirectAdmin از داخل پنل خودش دیتابیس و یوزر Postgres می‌سازد و حذف می‌کند، پسورد عوض می‌کند و دسترسی Grant/Revoke می‌دهد.
- ایزولاسیون کامل: کاربر `fred` فقط اسم‌هایی با پیشوند `da_fred_` را می‌بیند و می‌سازد (مثلاً `da_fred_shop`). امکان دیدن یا دستکاری دیتابیس کاربر دیگر وجود ندارد، چون کنترل دسترسی سمت سرور داخل `pg_helper.sh` انجام می‌شود نه فقط در ظاهر گرافیکی.
- بدون محدودیت تعداد (طبق خواسته شما): هر کاربر هر تعداد دیتابیس/یوزر بخواهد می‌سازد.
- هوک‌های خودکار: با ساخت یوزر DirectAdmin رول مربوطه ساخته می‌شود، با حذف یوزر همه دیتابیس‌ها و رول‌هایش پاک می‌شود، با Suspend/Unuspend دسترسی‌ها قفل/باز می‌شود.
- رابط انگلیسی، سازگار با Postgres 15 تا 18، بدون نیاز به pip اضافه (فقط `psql` و `python3` و `sudo` که معمولاً روی سرور هست).
- پشتیبانی از Debian/Ubuntu (با `apt`) و RHEL/Alma/Rocky (با `dnf`)؛ صفحه پیش‌نیازها داخل پنل ادمین وضعیت سیستم‌عامل و اجزا را نشان می‌دهد.

## پیش‌نیاز سرور

نصب Postgres اجباری نیست — اگر نصب نباشد، بعد از نصب پلاگین از داخل پنل ادمین (باکس Prerequisites) با یک دکمه نصب می‌شود. روش دستی (با root):

```bash
# دبیان/اوبونتو:
apt update && apt install -y postgresql sudo python3
pg_lsclusters   # باید online باشد

# RHEL/Alma/Rocky:
dnf install -y postgresql-server sudo python3
postgresql-setup --initdb && systemctl enable --now postgresql

psql --version
```

## نصب (دو روش)

### روش اول: از داخل پنل (بدون SSH، پیشنهادی)

1. با ادمین وارد DirectAdmin شوید: **Admin Level → Plugin Manager → Add Plugin** و فایل `postgres_manager.tar.gz` را آپلود و Install کنید (اسکریپت `install.sh` خودکار با root اجرا می‌شود).
2. منوی **PostgreSQL Manager** (سطح ادمین) را باز کنید:
   - باکس **Prerequisites** وضعیت سیستم‌عامل، `psql/sudo/python3` و کلاستر را نشان می‌دهد.
   - اگر چیزی قرمز (`missing`) بود و سرور Debian/Ubuntu است، دکمه **Install PostgreSQL (apt)** را بزنید (چند دقیقه طول می‌کشد). روی RHEL دستور دستی `dnf` نمایش داده می‌شود.
   - سبز شدن **Connection OK** یعنی آماده است.

### روش دوم: با SSH

```bash
# 1. کپی فایل بسته روی سرور (مثلاً با scp) سپس:
mkdir -p /usr/local/directadmin/plugins/postgres_manager
tar xzf postgres_manager.tar.gz -C /usr/local/directadmin/plugins/postgres_manager/
cd /usr/local/directadmin/plugins/postgres_manager
./scripts/install.sh
# اگر psql نصب نباشد فقط هشدار می‌دهد؛ بعداً از دکمه داخل پنل نصب کنید.

# 2. تست اتصال:
sudo -n -u postgres ./scripts/pg_helper.sh test --user admin
```

اسکریپت نصب این کارها را می‌کند:
- فایل `conf/pg.conf` را می‌سازد (پیش‌فرض سوکت محلی و کاربر `postgres` با احراز هویت peer، پس پسوردی ذخیره نمی‌شود).
- فایل `/etc/sudoers.d/da_postgres_manager` را می‌سازد تا هر کاربر فقط بتواند `pg_helper.sh` را با کاربر سیستمی `postgres` اجرا کند.
- دسترسی‌های اجرایی فایل‌های `user/admin/reseller` و هوک‌ها را تنظیم می‌کند.

اگر Postgres روی هاست/پورت دیگری است، فایل زیر را با root ویرایش کنید:

```
/usr/local/directadmin/plugins/postgres_manager/conf/pg.conf
```

## استفاده

- **کاربر:** در پنل کاربری منوی PostgreSQL Manager — ساخت دیتابیس، ساخت یوزر، تغییر پسورد، Grant/Revoke، دیدن سایز دیتابیس و اطلاعات اتصال.
- **ادمین:** منوی PostgreSQL Manager در سطح ادمین — باکس Prerequisites (وضعیت OS و اجزا + دکمه نصب)، وضعیت اتصال سرور، بررسی‌های `pg_hba`/رمزنگاری، جدول همه یوزرها با تعداد دیتابیس/رول و حجم، دکمه‌های Ensure / Suspend / Activate / Drop all، و صفحه Live activity (سشن‌ها با Kill، سایزها، لاک‌ها).
- **ریسلر:** جدول فقط‌خواندنی مصرف یوزرهای خودش.

نام کامل را برنامه می‌سازد: اسم کوتاهی که تایپ می‌کنید (مثلاً `shop`) تبدیل می‌شود به `da_fred_shop`. برای اتصال برنامه‌ها از همین نام کامل + پسوردی که ست کردید استفاده کنید:

```
psql -h SERVER_IP -p 5432 -U da_fred_app -d da_fred_shop
```

نکته اتصال ریموت: پورت 5432 را در فایروال باز کنید و در `pg_hba.conf` رکورد `scram-sha-256` اضافه کنید.

## حذف

از Plugin Manager حذف کنید یا:

```bash
/usr/local/directadmin/plugins/postgres_manager/scripts/uninstall.sh
```

دیتابیس‌ها و رول‌ها هنگام حذف پلاگین نگه داشته می‌شوند (فقط موقع حذف یوزر DirectAdmin پاک می‌شوند).

## عیب‌یابی

| مشکل | راه‌حل |
|---|---|
| `Connection FAILED` در پنل ادمین | `systemctl status postgresql` ، سپس `sudo -u postgres psql -c "SELECT 1;"` را تست کنید؛ `conf/pg.conf` را چک کنید |
| `sudo: interactive authentication is required` | `install.sh` را دوباره با root اجرا کنید تا sudoers ساخته شود؛ `visudo -c` |
| منوی پلاگین دیده نمی‌شود | `plugin.conf` باید `active=yes` باشد؛ یک بار DirectAdmin را restart کنید |
| خطای Peer authentication | هلپر باید با کاربر سیستمی `postgres` اجرا شود (از طریق sudo)؛ دستی با کاربر دیگر `psql -U postgres` نزنید |
| لاگین اپ به Postgres ناموفق (`ident authentication failed` یا `password authentication failed`) | اتصال TCP (هاست `127.0.0.1`) با `ident` فقط وقتی کار می‌کند که یوزر سیستمی = رول دیتابیس باشد؛ برای اپ باید در `pg_hba.conf` متد `scram-sha-256` باشد: `host all all 127.0.0.1/32 scram-sha-256` (و `::1/128`) سپس `systemctl reload postgresql`. بعد چک کن `SHOW password_encryption;` باید `scram-sha-256` باشد؛ اگر `md5` بود، در `postgresql.conf` عوضش کن و همه پسوردها را یک‌بار از پنل (change password) تازه کن، وگرنه پسوردهای قدیمی با scram کار نمی‌کنند |
| `missing password (PG_ROLE_PASS env)` یا SQL خالی در اکسپلورر | فایل sudoers قدیمی است؛ `install.sh` نسخه جدید را اجرا کنید تا `env_keep` اضافه شود |
| دکمه Install نمایش داده نمی‌شود ولی چیزی قرمز است | دکمه فقط روی Debian/Ubuntu (مدیر بسته `apt`) فعال است؛ روی RHEL دستور `dnf` داخل همان باکس را با root اجرا کنید |
| `This action requires POST` | دکمه را با کلیک/فرم بزنید، نه با لینک مستقیم یا رفرش GET؛ همه عملیات تغییردهنده فقط با POST اجرا می‌شوند |
