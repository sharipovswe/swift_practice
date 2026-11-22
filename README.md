# SwiftPractice

Учебный репозиторий по Swift: от основ языка до архитектурных решений уровня Senior / Lead iOS Engineer.

Цель — не только выучить синтаксис, а понять **почему** выбирается тот или иной подход, какие проблемы он решает и как применять его в production-приложениях.

## Содержание

- [Как устроен репозиторий](#как-устроен-репозиторий)
- [Требования](#требования)
- [Быстрый старт](#быстрый-старт)
- [Рекомендуемый порядок изучения](#рекомендуемый-порядок-изучения)
- [Карта тем](#карта-тем)
- [Структура каждого урока](#структура-каждого-урока)
- [Как запускать примеры](#как-запускать-примеры)
- [Архитектурные принципы, на которых построены примеры](#архитектурные-принципы)
- [Что планируется добавить](#что-планируется-добавить)
- [Соглашения по коду](#соглашения-по-коду)

## Как устроен репозиторий

```
SwiftPractice/
├── README.md
├── SwiftPractice.xcodeproj
└── SwiftPractice/
    ├── main.swift                          # Базовые темы (MARK 1–12) и ссылки на уроки
    │
    ├── Structures/
    │   └── Structures_Explanation.swift    # MARK 9:  структуры
    ├── Protocols/
    │   └── Protocols_Explanation.swift     # MARK 10: протоколы
    ├── ErrorHandling/
    │   └── ErrorHandling_Explanation.swift # MARK 11: обработка ошибок
    ├── Closures/
    │   └── Closures_Explanation.swift      # MARK 12: замыкания
    ├── OOP/
    │   └── AccessControl_Explanation.swift # модификаторы доступа и ООП
    │
    ├── Concurrency/
    │   ├── Sendable_Explanation.swift      # Sendable, @Sendable, nonisolated, where T: Sendable
    │   ├── Concurrency_Explanation.swift   # DispatchQueue, Task, @escaping, @MainActor
    │   └── AsyncStream_Explanation.swift   # AsyncStream.makeStream(), consumer, SDKListener
    │
    ├── SwiftUI/
    │   ├── State_Explanation.swift         # @State
    │   ├── Observable_Explanation.swift    # @Observable
    │   └── Bindable_Explanation.swift      # @Bindable
    │
    └── Combine/
        └── AnyPublisher_Explanation.swift  # AnyPublisher и type erasure
```

`main.swift` содержит краткие конспекты базовых тем (переменные, типы, опционалы, массивы, словари, функции, enum, классы). Подробные разборы вынесены в отдельные файлы: **каждая тема — один самостоятельный файл**. Любой файл можно открыть и изучить независимо от остальных, без поиска объяснений в других местах.

## Требования

| Что | Версия |
|---|---|
| Xcode | 16 и новее (проект проверялся на Swift 6.x toolchain) |
| Режим языка Swift | 5 (как в настройках проекта); код совместим и с проверкой `-strict-concurrency=complete` |
| macOS | 14+ для `@Observable` / `@Bindable` (Observation framework) |
| Платформа | macOS target (SwiftUI-примеры не запускаются как приложение, это учебные типы) |

> Примечание: `@Observable` и `@Bindable` доступны с iOS 17 / macOS 14. Для iOS 13–16 в файлах описан путь через `ObservableObject`.

## Быстрый старт

```bash
git clone <url-репозитория>
cd SwiftPractice
open SwiftPractice.xcodeproj
```

Откройте любой файл `*_Explanation.swift` и читайте сверху вниз: теория, затем примеры, затем production-сценарий, затем архитектурный анализ.

Проверка, что весь код компилируется (из каталога `SwiftPractice/SwiftPractice`):

```bash
swiftc -swift-version 5 -typecheck main.swift */*.swift
```

Проверка одного файла:

```bash
swiftc -swift-version 5 -parse-as-library -typecheck Concurrency/Sendable_Explanation.swift
```

Строгая проверка конкурентности (покажет предупреждения, которые станут ошибками в Swift 6):

```bash
swiftc -swift-version 5 -strict-concurrency=complete -parse-as-library -typecheck Concurrency/Concurrency_Explanation.swift
```

## Рекомендуемый порядок изучения

Темы зависят друг от друга. Идите по порядку, если изучаете с нуля.

1. **Основы** — `main.swift` (MARK 1–8).
2. **Structures** — значимые типы, на них строится почти всё остальное.
3. **Protocols** — абстракции и внедрение зависимостей.
4. **AccessControl / OOP** — инкапсуляция, наследование, `final`, `private(set)`.
5. **Closures** — основа замыканий, `@escaping`, `[weak self]`, retain cycle.
6. **ErrorHandling** — `throws`, `Result`, ошибки по слоям, retry.
7. **Concurrency** — сначала `Concurrency_Explanation`, затем `Sendable_Explanation`, затем `AsyncStream_Explanation`.
8. **SwiftUI** — `State`, затем `Observable`, затем `Bindable`.
9. **Combine** — `AnyPublisher_Explanation`.

## Карта тем

| Тема | Файл | Что разбирается | Когда читать |
|---|---|---|---|
| Структуры | `Structures/Structures_Explanation.swift` | value semantics, `mutating`, Value Object, DTO ↔ Domain, ViewState, Reducer, Copy-on-Write, property wrapper | после основ |
| Протоколы | `Protocols/Protocols_Explanation.swift` | default implementation, associated types, `some` vs `any`, Strategy, Repository, Decorator, Composition Root | после структур |
| Ошибки | `ErrorHandling/ErrorHandling_Explanation.swift` | `throws`, `rethrows`, typed throws, `Result`, `TaskGroup`, маппинг ошибок по слоям, retry с backoff | после протоколов |
| Замыкания | `Closures/Closures_Explanation.swift` | захват контекста, `@escaping`, `@autoclosure`, capture list, struct-of-closures, debounce | после ошибок |
| Доступ / ООП | `OOP/AccessControl_Explanation.swift` | `open`/`public`/`internal`/`private`, `final`, `override`, `static` vs `class`, инициализаторы | параллельно с протоколами |
| Sendable | `Concurrency/Sendable_Explanation.swift` | `Sendable`, `@Sendable`, `nonisolated`, `where T: Sendable`, `@unchecked`, `sending`, actor | после замыканий |
| Многопоточность | `Concurrency/Concurrency_Explanation.swift` | GCD, `Task`, `async let`, `@MainActor`, миграция с callback на async | перед Sendable |
| AsyncStream | `Concurrency/AsyncStream_Explanation.swift` | `makeStream()`, буферизация, consumer, `SDKListener` → событие, broadcast hub | после Sendable |
| @State | `SwiftUI/State_Explanation.swift` | source of truth, `@Binding`, enum-состояние, формы | перед Observable |
| @Observable | `SwiftUI/Observable_Explanation.swift` | гранулярное отслеживание, `@ObservationIgnored`, ViewModel, масштабирование | после @State |
| @Bindable | `SwiftUI/Bindable_Explanation.swift` | `$`-биндинги к объектам, черновик + коммит, вложенные модели | после @Observable |
| Combine | `Combine/AnyPublisher_Explanation.swift` | type erasure, `eraseToAnyPublisher`, `Subject`, debounce, `switchToLatest`, мост в async | последним |

## Структура каждого урока

Каждый файл устроен одинаково, чтобы его можно было изучать как самостоятельный материал:

1. **Теория** — как это работает и зачем нужно.
2. **Синтаксис и базовые примеры** — с комментариями на русском.
3. **Практические сценарии** — несколько разных случаев использования.
4. **Production-пример** — как это выглядит в большом приложении (слои, зависимости, тесты).
5. **Архитектурный анализ** — когда применять, а когда это избыточно; плюсы и минусы.
6. **Типичные ошибки и best practices.**
7. **Связь с другими механизмами** — SOLID, Clean Architecture, многопоточность, SwiftUI, Combine.

## Как запускать примеры

Каждый урок вынесен в неймспейс-`enum` (например, `StructuresLesson`) и имеет метод `run()`. Чтобы запустить его, вызовите из `main.swift`:

```swift
// Синхронный урок
AccessControlLesson.run()

// Асинхронные уроки
Task { await StructuresLesson.run() }
Task { await AsyncStreamLesson.run() }

// Чтобы консольная программа не завершилась раньше асинхронных задач:
RunLoop.main.run(until: Date().addingTimeInterval(2))
```

Доступные неймспейсы: `StructuresLesson`, `ProtocolsLesson`, `ErrorHandlingLesson`, `ClosuresLesson`, `AccessControlLesson`, `SendableLesson`, `ConcurrencyLesson`, `AsyncStreamLesson`, `StateLesson`, `ObservableLesson`, `BindableLesson`, `AnyPublisherLesson`.

> SwiftUI-типы (`State`, `Observable`, `Bindable`) — это учебные View и модели. Их удобно проверять через Xcode Previews в отдельном SwiftUI-проекте, скопировав нужный тип.

### Почему всё в неймспейсах

Все файлы входят в один модуль. Если два файла объявят тип `User` или `Order`, будет конфликт имён. Вложенность в `enum` без `case` решает проблему и показывает, что тип относится к конкретному уроку.

В SwiftUI-файлах написано `SwiftUI.View`, потому что в `main.swift` объявлен учебный класс `View`, который иначе затенил бы протокол SwiftUI.

## Архитектурные принципы

Примеры сквозным образом иллюстрируют:

- **Clean Architecture** — слои Presentation / Domain / Data, зависимости направлены к домену; DTO, Domain-модель и ViewState — отдельные типы.
- **SOLID** — SRP (маппер, use case, репозиторий — отдельно), OCP (расширение через протоколы), LSP (подмена реализаций), ISP (малые протоколы), DIP (зависимость от абстракции).
- **Dependency Injection** — через `init`, протоколы и замыкания; Composition Root; тестовые двойники.
- **Безопасная конкурентность** — иммутабельные `Sendable`-модели, `actor` для общего состояния, `@MainActor` для UI, структурная отмена.
- **Однонаправленный поток данных** — состояние живёт у одного владельца, вниз идёт чтение, вверх — события.

## Что планируется добавить

- `Actor_Explanation.swift` — reentrancy, `isolated`, `Mutex`, свой `GlobalActor`.
- `TaskGroup_Explanation.swift` — ограничение параллелизма, `withDiscardingTaskGroup`.
- `Cancellation_Explanation.swift` — `withTaskCancellationHandler`, таймауты и дедлайны.
- `TaskLocal_Explanation.swift` — трассировка запросов.
- `AsyncSequence_Explanation.swift` — самописные последовательности и `swift-async-algorithms`.
- `Testing_Explanation.swift` — тестирование async-кода, `Clock`, `TestClock`.
- `Swift6Migration_Explanation.swift` — strict concurrency, `@preconcurrency`, `@concurrent`.
- Каталог `Tests/` с юнит-тестами примеров (`CartReducer`, `retrying`, `EventHub`).
- Мини-проект, собирающий всё вместе: лента, поиск, кэш, оффлайн.

## Соглашения по коду

- Комментарии в учебных файлах — на русском; идентификаторы — на английском.
- Один файл — одна тема; тип в неймспейсе `<Тема>Lesson`.
- `final class` по умолчанию; `struct` для данных; `private` по умолчанию.
- Публичные Sendable-типы помечаются `Sendable` явно.
- Каждый файл должен проходить `swiftc -typecheck` без ошибок.
