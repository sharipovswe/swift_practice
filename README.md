# SwiftPractice

Учебный репозиторий по Swift: от основ языка до архитектурных решений уровня Senior / Lead iOS Engineer.

Цель — не только выучить синтаксис, а понять **почему** выбирается тот или иной подход, какие проблемы он решает и как применять его в production-приложениях.

## Содержание

- [Как устроен репозиторий](#как-устроен-репозиторий)
- [Требования](#требования)
- [Тесты](#тесты)
- [Быстрый старт](#быстрый-старт)
- [Рекомендуемый порядок изучения](#рекомендуемый-порядок-изучения)
- [Карта тем](#карта-тем)
- [Структура каждого урока](#структура-каждого-урока)
- [Как запускать примеры](#как-запускать-примеры)
- [Архитектурные принципы, на которых построены примеры](#архитектурные-принципы)
- [Что можно добавить дальше](#что-можно-добавить-дальше)
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
    │   ├── Concurrency_Explanation.swift   # DispatchQueue, Task, @escaping, @MainActor
    │   ├── Sendable_Explanation.swift      # Sendable, @Sendable, nonisolated, where T: Sendable
    │   ├── Actor_Explanation.swift         # actor, reentrancy, isolated, Mutex, GlobalActor
    │   ├── TaskGroup_Explanation.swift     # TaskGroup, лимит параллелизма, discarding group
    │   ├── Cancellation_Explanation.swift  # отмена, таймауты, дедлайны
    │   ├── TaskLocal_Explanation.swift     # @TaskLocal, трассировка запросов
    │   ├── AsyncStream_Explanation.swift   # AsyncStream.makeStream(), consumer, SDKListener
    │   ├── AsyncSequence_Explanation.swift # свои AsyncSequence, debounce, merge, async-algorithms
    │   ├── Testing_Explanation.swift       # тесты async-кода, ManualClock
    │   └── Swift6Migration_Explanation.swift # Swift 6, @preconcurrency, @concurrent
    │
    ├── SwiftUI/
    │   ├── State_Explanation.swift         # @State
    │   ├── Observable_Explanation.swift    # @Observable
    │   └── Bindable_Explanation.swift      # @Bindable
    │
    ├── Combine/
    │   └── AnyPublisher_Explanation.swift  # AnyPublisher и type erasure
    │
    └── MiniProject/
        └── FeedApp_MiniProject.swift       # лента + поиск + кэш + оффлайн (всё вместе)

Package.swift                               # для `swift test` из консоли и CI
Tests/                                      # юнит-тесты примеров (XCTest + Swift Testing)
├── StructuresTests.swift                   # CartReducer, Value Objects, Mapper
├── ErrorHandlingTests.swift                # retrying, маппинг ошибок (XCTest)
├── AsyncStreamTests.swift                  # EventHub, SDK-адаптер
├── ConcurrencyTests.swift                  # actor, TaskGroup, отмена, ManualClock
└── MiniProjectTests.swift                  # кэш, оффлайн, поиск, пагинация
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

## Тесты

В репозитории есть `Package.swift`, который собирает те же исходники (без `main.swift`) как библиотеку и подключает каталог `Tests/`. Это позволяет запускать тесты из консоли и на CI, не трогая Xcode-проект.

```bash
swift test
```

Сейчас: 9 тестов XCTest и 38 тестов Swift Testing, все проходят. Тесты не используют реальную сеть и реальное время: сеть подменена фейками, время — `ManualClock` (см. `Testing_Explanation.swift`).

Что показывают тесты:
- `CartReducer`, Value Object, mapper — тесты чистой логики без UI;
- `retrying` — повтор только транзитных ошибок, отмена не повторяется;
- `EventHub`, SDK-адаптер — события доставляются всем подписчикам, отписка при отмене;
- reentrancy в `actor` (баг воспроизводится и исправление проверяется), единственный refresh токена;
- лимит параллелизма в `TaskGroup`, таймауты, мост отмены к legacy API;
- debounce и retry на `ManualClock` за 0 мс реального времени;
- мини-проект: кэш, оффлайн-режим, поиск, пагинация, авто-обновление при возврате сети.

В Xcode: тесты из `Tests/` можно подключить к отдельному Unit Test target с `@testable import SwiftPractice`, либо открыть `Package.swift` как пакет.

## Рекомендуемый порядок изучения

Темы зависят друг от друга. Идите по порядку, если изучаете с нуля.

1. **Основы** — `main.swift` (MARK 1–8).
2. **Structures** — значимые типы, на них строится почти всё остальное.
3. **Protocols** — абстракции и внедрение зависимостей.
4. **AccessControl / OOP** — инкапсуляция, наследование, `final`, `private(set)`.
5. **Closures** — основа замыканий, `@escaping`, `[weak self]`, retain cycle.
6. **ErrorHandling** — `throws`, `Result`, ошибки по слоям, retry.
7. **Concurrency, базовый уровень** — `Concurrency_Explanation`, затем `Sendable_Explanation`.
8. **Concurrency, углублённо** — `Actor`, `TaskGroup`, `Cancellation`, `TaskLocal`.
9. **Потоки событий** — `AsyncStream`, затем `AsyncSequence`.
10. **SwiftUI** — `State`, затем `Observable`, затем `Bindable`.
11. **Combine** — `AnyPublisher_Explanation`.
12. **Тестирование и миграция** — `Testing_Explanation`, `Swift6Migration_Explanation`, затем `Tests/`.
13. **Мини-проект** — `FeedApp_MiniProject.swift`: найдите в нём применение каждого урока.

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
| Actor | `Concurrency/Actor_Explanation.swift` | изоляция, **reentrancy** (баг и исправление), `isolated`-параметры, `Mutex`, свой `GlobalActor`, токен с единственным refresh | после Sendable |
| TaskGroup | `Concurrency/TaskGroup_Explanation.swift` | `async let` vs группа, порядок результатов, скользящее окно (лимит), `withDiscardingTaskGroup`, частичный успех | после Actor |
| Отмена | `Concurrency/Cancellation_Explanation.swift` | кооперативная модель, `withTaskCancellationHandler`, таймауты, дедлайны, очистка ресурсов | после TaskGroup |
| TaskLocal | `Concurrency/TaskLocal_Explanation.swift` | неявный контекст задачи, наследование, трассировка запросов, подмена `Date`/`UUID` | после Отмены |
| AsyncStream | `Concurrency/AsyncStream_Explanation.swift` | `makeStream()`, буферизация, consumer, `SDKListener` → событие, broadcast hub | после Sendable |
| AsyncSequence | `Concurrency/AsyncSequence_Explanation.swift` | свой итератор, пагинация как последовательность, `debounce`/`chunked`/`merge` вручную, `swift-async-algorithms`, мосты Combine ↔ async | после AsyncStream |
| Тестирование | `Concurrency/Testing_Explanation.swift` | почему тесты flaky, `Clock` как зависимость, свой `ManualClock`, XCTest и Swift Testing | после Отмены |
| Swift 6 | `Concurrency/Swift6Migration_Explanation.swift` | план миграции, шпаргалка диагнозов, `@preconcurrency`, `@concurrent`, `nonisolated(nonsending)`, `sending` | последним в Concurrency |
| @State | `SwiftUI/State_Explanation.swift` | source of truth, `@Binding`, enum-состояние, формы | перед Observable |
| @Observable | `SwiftUI/Observable_Explanation.swift` | гранулярное отслеживание, `@ObservationIgnored`, ViewModel, масштабирование | после @State |
| @Bindable | `SwiftUI/Bindable_Explanation.swift` | `$`-биндинги к объектам, черновик + коммит, вложенные модели | после @Observable |
| Combine | `Combine/AnyPublisher_Explanation.swift` | type erasure, `eraseToAnyPublisher`, `Subject`, debounce, `switchToLatest`, мост в async | после SwiftUI |
| Мини-проект | `MiniProject/FeedApp_MiniProject.swift` | лента, пагинация, поиск с debounce, кэш с TTL, оффлайн-режим, мониторинг сети; Clean Architecture целиком | в конце |

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

Доступные неймспейсы: `StructuresLesson`, `ProtocolsLesson`, `ErrorHandlingLesson`, `ClosuresLesson`, `AccessControlLesson`, `SendableLesson`, `ConcurrencyLesson`, `ActorLesson`, `TaskGroupLesson`, `CancellationLesson`, `TaskLocalLesson`, `AsyncStreamLesson`, `AsyncSequenceLesson`, `TestingLesson`, `Swift6MigrationLesson`, `StateLesson`, `ObservableLesson`, `BindableLesson`, `AnyPublisherLesson`, `FeedApp` (мини-проект).

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

## Что можно добавить дальше

- `SwiftData` / `CoreData` и конкурентность (`ModelActor`, `NSManagedObjectContext.perform`).
- Навигация: `NavigationStack`, Coordinator/Router, deep links.
- Сеть в production: `URLSession` клиент с интерсепторами, refresh токена, certificate pinning.
- Модуляризация: SPM-пакеты по слоям, правила зависимостей.
- Паттерн-архитектуры: TCA / MVVM-C / VIPER — сравнение на мини-проекте.
- Профилирование: Instruments, Swift Concurrency instrument, поиск утечек.
- Подключение настоящего `NWPathMonitor` и файлового кэша к `FeedApp`.

## Соглашения по коду

- Комментарии в учебных файлах — на русском; идентификаторы — на английском.
- Один файл — одна тема; тип в неймспейсе `<Тема>Lesson`.
- `final class` по умолчанию; `struct` для данных; `private` по умолчанию.
- Публичные Sendable-типы помечаются `Sendable` явно.
- Каждый файл должен проходить `swiftc -typecheck` без ошибок; уроки по конкурентности проходят и с `-strict-concurrency=complete`, и в режиме Swift 6 (проверено для всех файлов `Concurrency/` и `SwiftUI/`).
- Новое поведение сопровождается тестом в `Tests/`; `swift test` должен быть зелёным.
