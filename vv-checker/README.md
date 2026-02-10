# VkusVill Availability Checker (Puppeteer)

Микросервис проверки наличия товаров ВкусВилл по адресу доставки. Работает на хосте (вне Docker), используя headless Chrome через Puppeteer.

## Зачем

MCP API ВкусВилл (`vkusvill_products_search`, `vkusvill_product_details`) не возвращает данные о наличии по конкретному адресу доставки. Наличие показывается только на странице товара для авторизованного пользователя с выбранным адресом.

Сервер ВкусВилл отдаёт блок наличия (`#product-quantity-block`) только настоящему браузеру — curl с любыми куками и заголовками не работает (проверяется TLS fingerprint / серверная сессия).

## Архитектура

```
Docker (OpenClaw бот)
    │
    │  curl http://host.docker.internal:18790/check?url=...
    │
    ▼
Host (systemd: vv-checker)
    │
    │  Puppeteer → headless Chrome
    │  userDataDir: /opt/vv-checker/chrome-data/
    │
    ▼
vkusvill.ru (авторизованная сессия с адресом)
```

## Расположение на сервере

```
/opt/vv-checker/
├── server.js              # HTTP-сервер (порт 18790)
├── package.json           # Зависимости (puppeteer)
├── node_modules/          # npm пакеты
├── chrome-data/           # Persistent Chrome profile (куки, сессии)
└── cookies.json           # Бэкап кук (опционально)

/etc/systemd/system/vv-checker.service  # Systemd unit
```

## API Endpoints

| Метод | URL | Описание |
|-------|-----|----------|
| GET | `/health` | Статус сервиса, браузера, адреса |
| GET | `/check?url=<product_url>` | Проверка наличия товара |
| GET | `/open?url=<url>` | Открыть URL в headless Chrome (для ручной настройки) |
| GET | `/save-cookies` | Сохранить куки текущей сессии в файл |

### Ответ `/check`

```json
{
  "status": "available",
  "quantity": 4,
  "text": "Доставим сегодня/завтра",
  "classes": "ProductLkRest _tomorrow ...",
  "productName": "Паста Орзо с куриными фрикадельками",
  "url": "https://vkusvill.ru/goods/...",
  "hasAddress": true,
  "addressText": "улица Примерная, 1"
}
```

**Статусы:**
- `available` — товар есть, `quantity > 0`
- `not_available` — товара нет, `quantity = 0`
- `unknown` — блок наличия не найден (сессия протухла или страница не та)

## Первоначальная настройка

### 1. Установка

```bash
# Node.js 20
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install nodejs -y

# Chrome зависимости
sudo apt install -y libgbm1 libasound2 libatk1.0-0 libatk-bridge2.0-0 \
  libcups2 libdrm2 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
  libpango-1.0-0 libcairo2 libnspr4 libnss3 libxshmfence1

# Проект
mkdir -p /opt/vv-checker && cd /opt/vv-checker
# Скопировать server.js и package.json из этого репо (vv-checker/)
npm install

# Systemd
cp vv-checker.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable vv-checker
systemctl start vv-checker
```

### 2. Авторизация в headless Chrome (ручная, одноразовая)

Нужно один раз войти в ВкусВилл через headless Chrome, чтобы сессия сохранилась в `chrome-data/`. Это критический шаг — без авторизованной сессии `/check` будет возвращать `status: "unknown"`.

**Как это работает:** Puppeteer запускает Chrome с `--remote-debugging-port=9222`. Через SSH port forwarding мы подключаемся к этому Chrome с локальной машины через `chrome://inspect` и управляем им руками — заходим на сайт, логинимся, выбираем адрес. После этого сессия сохраняется в `chrome-data/` и используется автоматически.

**Через SSH (или Termius Port Forwarding):**

```bash
# Вариант 1: SSH напрямую
ssh -L 9222:127.0.0.1:9222 user@server

# Вариант 2: Termius Port Forwarding
# Type: Local
# Local Host: 127.0.0.1
# Local Port: 9222
# Destination Host: 127.0.0.1
# Destination Port: 9222
# SSH Server: ваш сервер
```

**Шаги:**

1. Включить Port Forwarding (настройки выше)
2. Открыть страницу в headless Chrome:
   ```bash
   # С сервера:
   curl http://127.0.0.1:18790/open?url=https://vkusvill.ru/
   ```
3. На локальной машине открыть Chrome → `chrome://inspect`
4. Нажать **Configure...** → добавить `localhost:9222`
5. Внизу появится remote target → нажать **inspect**
6. В открывшемся DevTools — зайти на ВкусВилл, авторизоваться, выбрать адрес доставки
7. Закрыть DevTools, отключить Port Forwarding

**Адрес обычно подтягивается автоматически** по куке `_vv_card` (номер карты лояльности). Если нет — выбрать вручную.

### 3. Проверка

```bash
curl -s 'http://127.0.0.1:18790/check?url=https://vkusvill.ru/goods/pasta-orzo-s-kurinymi-frikadelkami-98052.html'
# Должен вернуть status: "available" или "not_available"
# Если status: "unknown" и hasAddress: false — сессия не настроена, повторите шаг 2
```

## Подключение к Docker (OpenClaw)

### docker-compose.yml

```yaml
services:
  openclaw-gateway:
    # ... существующие настройки ...
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

Это добавляет запись в `/etc/hosts` внутри контейнера: `host.docker.internal → IP хоста`. Не влияет на обновления образа OpenClaw.

### UFW: разрешить Docker → vv-checker

```bash
# Узнать подсеть Docker:
docker inspect openclaw-gateway --format '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}'

# Добавить правила (обычно нужны обе подсети):
ufw allow from 172.17.0.0/16 to any port 18790 comment 'vv-checker from Docker'
ufw allow from 172.18.0.0/16 to any port 18790 comment 'vv-checker from Docker compose'
```

**Важно:** docker-compose создаёт свою сеть (обычно `172.18.0.0/16`), а не использует default bridge (`172.17.0.0/16`). Нужны оба правила.

### Интеграция с ботом

Проверка наличия встроена в основной скрипт `vkusvill.sh` как подкоманда `check`:

```bash
# Бот вызывает так (из Docker):
exec /home/node/.openclaw/workspace/skills/vkusvill/vkusvill.sh check 98052

# Принимает ID товара (число) или полный URL
exec /home/node/.openclaw/workspace/skills/vkusvill/vkusvill.sh check https://vkusvill.ru/goods/xmlid/98052
```

ID автоматически конвертируется в `https://vkusvill.ru/goods/xmlid/<ID>`.

Ответ: `AVAILABLE|кол-во|описание` или `NOT_AVAILABLE|0|описание`

## Обслуживание

### Управление сервисом

```bash
systemctl status vv-checker     # статус
systemctl restart vv-checker    # перезапуск
systemctl stop vv-checker       # остановка
journalctl -u vv-checker -f     # логи в реальном времени
```

### Keepalive (cron)

Раз в день (10:00 МСК) делается запрос к `/check` чтобы обновить куки сессии:

```cron
0 10 * * * curl -s http://127.0.0.1:18790/check?url=https://vkusvill.ru/goods/pasta-orzo-s-kurinymi-frikadelkami-98052.html > /dev/null 2>&1
```

### Срок жизни кук

| Кука | Срок | Роль |
|------|------|------|
| `acs_3` | ~400 дней | Хеш авторизации |
| `_vv_card` | ~365 дней | Номер карты лояльности |
| `UF_USER_AUTH` | ~360 дней | Флаг авторизации |
| `adrdel` | ~400 дней | Метка времени адреса |
| `adrcid` | ~400 дней | ID адреса |
| `domain_sid` | 7 дней | Сессия домена |
| `__Host-PHPSESSID` | Сессионная | PHP-сессия (главная!) |
| `SERVERID` | Сессионная | Привязка к серверу |

**Самые уязвимые:** `domain_sid` (7 дней) и `__Host-PHPSESSID` (сессионная, но хранится в `chrome-data/`). Keepalive обновляет обе ежедневно.

### Если сессия протухла

Признак: `/check` возвращает `status: "unknown"` и `hasAddress: false`.

Решение: повторить процедуру авторизации (шаг 2 из "Первоначальная настройка").

### Память

Сервис занимает ~130-150 MB (Node.js + headless Chrome). На VPS с 2GB RAM это нормально.

## Безопасность и порты

| Порт | Назначение | Bind | Доступ |
|------|-----------|------|--------|
| 18790 | HTTP API сервиса | `0.0.0.0` | localhost + docker bridge |
| 9222 | Chrome Remote Debugging | `127.0.0.1` | только localhost |

**UFW** должен быть включён. Порт 18790 разрешён **только** для Docker-сетей. Из интернета порт закрыт.

```bash
ufw status
# 22/tcp    ALLOW IN    Anywhere
# 18790     ALLOW IN    172.17.0.0/16   # vv-checker from Docker
# 18790     ALLOW IN    172.18.0.0/16   # vv-checker from Docker compose
```

Доступ к порту 9222 — только через SSH port forwarding (bind 127.0.0.1).

## Что НЕ работает (и почему)

### curl с куками
Пробовали curl с полным набором кук (11 штук) + все заголовки браузера. Блок `#product-quantity-block` не появляется. Сервер ВкусВилл проверяет TLS fingerprint или глубокую валидацию сессии — только настоящий браузер (Chrome) проходит проверку.

### Schema.org InStock
`schema.org` разметка (`InStock`) всегда присутствует на странице товара, независимо от реального наличия по адресу. Нельзя использовать как индикатор.

### Куки без PHP-сессии
Куки `_vv_card`, `UF_USER_AUTH`, `adrdel` etc. без валидной `__Host-PHPSESSID` не дают наличие. Адрес доставки привязан к серверной PHP-сессии, а не к кукам клиента.
