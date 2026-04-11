# Contributing

## Ветки

От `develop`, PR → `develop`. Мёрж в `main` через CI/CD.

Формат: `<тип>/<краткое-описание>` (дефис, строчные).  
Примеры: `feat/vk-keyboard-templates`, `fix/deepseek-rate-limit`

## Коммиты

Формат: `<тип>: <что сделано>` (до 72 символов, повелительное наклонение).  
Примеры: `feat: add live interview mode`, `fix: prevent redis session leak`

- Одно логическое изменение на коммит.
- Тело только для объяснения *почему*.
- Не коммитить `.env`, токены в `.env.example`.

## Pull Requests

**Название** как у коммита: `feat: support user question upload`

**Описание:**
- Что сделано
- Зачем (если неочевидно)
- Как проверить (команды, тесты, curl)

- PR → одна задача, до ~1000 строк.
- Draft: `Draft: <название>`.
- Ревью в течение рабочего дня, иначе можно мёржить самому.

## Правила проекта

- **Секреты:** никогда не коммитить `.env`. В `.env.example` — все ключи-заглушки.
- **API:** мокать VK/DeepSeek через `webmock`/`rspec-mocks`. Реальные запросы только в integration-тестах.
- **Redis:** тесты используют `REDIS_URL=redis://localhost:6379/1`. У всех временных ключей TTL (1 час).
- **LLM промпты:** хранить в `apis/deepseek.rb` или `config/prompts.yml`. Указывать версию при изменениях.
- **Docker:** синхронизировать `Dockerfile` и `docker-compose.yml`. Перед PR проверять `docker compose up --build`. В SourceCraft — `PORT=4567`, логи в `stdout`.
