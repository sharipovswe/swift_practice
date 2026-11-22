// ============================================================================
// Bindable_Explanation.swift
// @Bindable — биндинги к свойствам @Observable-объектов (iOS 17+)
// Уровень: Senior / Lead iOS Engineer
// ============================================================================
//
// СОДЕРЖАНИЕ
//  1. Теория: зачем нужен @Bindable, чем отличается от @State/@Binding
//  2. Как работает: Bindable<T>, projectedValue, dynamic member lookup
//  3. Сценарии: параметр View, локальная переменная в body, Environment,
//     вложенные модели, Optional, коллекции, struct Data
//  4. Взаимодействие @State + @Observable + @Bindable (таблица ролей)
//  5. Production-пример: форма редактирования профиля (master-detail)
//  6. Архитектурный анализ, ошибки, best practices
//  7. Связь с Clean Architecture, SOLID, concurrency
//
// Типы лежат в неймспейсе `BindableLesson`; `View` -> `SwiftUI.View`.
// ============================================================================

import SwiftUI
import Observation

enum BindableLesson {

    // ========================================================================
    // 1. ТЕОРИЯ
    // ========================================================================
    //
    // Проблема: у @Observable-объекта есть свойства (var name: String).
    // TextField/Toggle/Picker/Slider требуют Binding<String> — "ручку" для
    // чтения И записи. У обычной ссылки на объект $-синтаксиса НЕТ:
    //
    //     let model: Model
    //     TextField("Имя", text: $model.name)   // ОШИБКА: нет проекции `$model`
    //
    // @Bindable — property wrapper (iOS 17+), который оборачивает ссылку на
    // @Observable-объект и ДАЁТ `$model`, а через него — `$model.name` ->
    // Binding<String> на конкретное свойство.
    //
    // ВАЖНО: @Bindable НЕ ВЛАДЕЕТ объектом и не хранит состояние. Он не
    // вызывает перерисовку сам по себе (это делает Observation при чтении
    // свойств в body). Его единственная задача — создавать Binding'и.
    //
    // Сравнение:
    //   @State     — View ВЛАДЕЕТ значением/моделью (хранит, создаёт один раз)
    //   @Binding   — View получила "ручку" на ЧУЖОЕ ЗНАЧЕНИЕ (Binding<Value>)
    //   @Bindable  — View получила ЧУЖОЙ @Observable-ОБЪЕКТ и хочет $-ручки
    //                на его свойства
    //   let model  — только читаем (без записи через UI)
    //
    // Замена старому коду: `@ObservedObject var model` (для $-биндингов).

    // ========================================================================
    // 2. КАК РАБОТАЕТ
    // ========================================================================
    //
    // struct Bindable<Value: AnyObject & Observable>:
    //   - wrappedValue  : сам объект
    //   - projectedValue: сам Bindable (`$model`)
    //   - @dynamicMemberLookup: `$model.name` ->
    //        subscript(dynamicMember: ReferenceWritableKeyPath<Value, T>) -> Binding<T>
    //     Внутри Binding: get читает model[keyPath:], set пишет в него.
    //     Запись в @Observable-свойство вызывает withMutation -> Observation
    //     уведомляет View, прочитавшие это свойство -> body пересчитывается.
    //
    // Т.е. цепочка: TextField печатает -> Binding.set -> model.name = ...
    //   -> Observation -> перерисовка тех View, что читали name.

    @Observable
    final class Profile {
        var name = ""
        var bio = ""
        var isPublic = false
        var age = 18
        var notifications = Notifications()          // вложенная @Observable-модель
        var tags: [String] = []
    }

    @Observable
    final class Notifications {
        var push = true
        var email = false
    }

    // ------------------------------------------------------------------------
    // Сценарий A. @Bindable как параметр View (самый частый).
    // ------------------------------------------------------------------------
    // Родитель владеет моделью (@State) и передаёт ссылку; ребёнок
    // редактирует её через @Bindable.

    struct ProfileForm: SwiftUI.View {
        @Bindable var profile: Profile                 // не private: задаётся через init

        var body: some SwiftUI.View {
            Form {
                TextField("Имя", text: $profile.name)             // Binding<String>
                TextField("О себе", text: $profile.bio, axis: .vertical)
                Toggle("Публичный профиль", isOn: $profile.isPublic)
                Stepper("Возраст: \(profile.age)", value: $profile.age, in: 0...120)

                // Вложенный @Observable: цепочка $profile.notifications.push
                Toggle("Push", isOn: $profile.notifications.push)
                Toggle("Email", isOn: $profile.notifications.email)
            }
        }
    }

    struct ProfileScreen: SwiftUI.View {
        @State private var profile = Profile()          // ВЛАДЕЛЕЦ: @State
        var body: some SwiftUI.View {
            ProfileForm(profile: profile)               // передаём объект, не $profile
        }
    }

    // ------------------------------------------------------------------------
    // Сценарий B. Локальный @Bindable в body — когда модель не параметр-обёртка.
    // ------------------------------------------------------------------------
    // Модель получена из @Environment, из @State-владения или из элемента
    // коллекции. Объявляем `@Bindable var x = model` ВНУТРИ body, чтобы
    // получить `$x`. Это дёшево: Bindable — лёгкая struct-обёртка над ссылкой.

    struct EnvironmentForm: SwiftUI.View {
        @Environment(Profile.self) private var profile    // читаем из окружения

        var body: some SwiftUI.View {
            @Bindable var profile = profile                // локальная "переменная для $"
            TextField("Имя", text: $profile.name)
        }
    }
    // Положить в окружение: ContentView().environment(Profile())

    struct OwnedModelForm: SwiftUI.View {
        @State private var model = Profile()
        var body: some SwiftUI.View {
            // Для @State-модели $model.name даёт Binding<…>? НЕТ: `$model` здесь —
            // Binding<Profile> (проекция @State), а `$model.name` работает через
            // dynamicMember на Binding, т.к. Profile — @Observable class.
            // Поэтому для @State-модели отдельный @Bindable НЕ нужен:
            TextField("Имя", text: $model.name)
        }
    }

    // ------------------------------------------------------------------------
    // Сценарий C. Список моделей + @Bindable на элемент (master-detail).
    // ------------------------------------------------------------------------

    @Observable
    final class TodoItem: Identifiable {
        let id = UUID()
        var title: String
        var done = false
        init(title: String) { self.title = title }
    }

    @Observable
    final class TodoList {
        var items: [TodoItem] = [TodoItem(title: "Изучить @Bindable")]
        func add() { items.append(TodoItem(title: "Новая")) }
    }

    struct TodoRow: SwiftUI.View {
        @Bindable var item: TodoItem                     // каждая строка редактирует СВОЙ элемент
        var body: some SwiftUI.View {
            HStack {
                Toggle("", isOn: $item.done).labelsHidden()
                TextField("Название", text: $item.title)
            }
        }
    }

    struct TodoScreen: SwiftUI.View {
        @State private var list = TodoList()
        var body: some SwiftUI.View {
            List(list.items) { item in TodoRow(item: item) }  // перерисовывается ТОЛЬКО строка,
            // у которой изменился title/done: гранулярность Observation
        }
    }

    // ------------------------------------------------------------------------
    // Сценарий D. Optional-модель.
    // ------------------------------------------------------------------------
    // @Bindable на Optional не работает напрямую — разворачиваем:
    struct OptionalForm: SwiftUI.View {
        var profile: Profile?
        var body: some SwiftUI.View {
            if let profile {
                OptionalInner(profile: profile)          // внутри — @Bindable
            } else {
                Text("Нет данных")
            }
        }
    }
    struct OptionalInner: SwiftUI.View {
        @Bindable var profile: Profile
        var body: some SwiftUI.View { TextField("Имя", text: $profile.name) }
    }

    // ------------------------------------------------------------------------
    // Сценарий E. Модель-значение (struct Data) внутри @Observable.
    // ------------------------------------------------------------------------
    // struct не может быть @Bindable (нужен class). Для struct-ПОЛЕЙ внутри
    // @Observable-объекта работают обычные key-path биндинги через $model.field.

    struct Data: Equatable { var name: String; var count: Int }   // затеняет Foundation.Data здесь

    @Observable
    final class DataModel {
        var data = Data(name: "Начало", count: 0)       // struct внутри class
    }

    struct DataView: SwiftUI.View {
        @Bindable var model: DataModel
        var body: some SwiftUI.View {
            VStack {
                // Binding на ВЛОЖЕННОЕ поле struct: запись -> новая копия Data -> модель
                // получает уведомление о смене свойства `data`.
                TextField("Имя", text: $model.data.name)
                Stepper("Счёт: \(model.data.count)", value: $model.data.count)
            }
        }
    }

    // ------------------------------------------------------------------------
    // Сценарий F. Кастомный Binding поверх @Bindable (валидация/преобразование).
    // ------------------------------------------------------------------------
    struct ValidatedField: SwiftUI.View {
        @Bindable var profile: Profile
        var body: some SwiftUI.View {
            // Binding(get:set:): обрезаем до 20 символов при записи
            let limited = Binding(
                get: { profile.name },
                set: { profile.name = String($0.prefix(20)) }
            )
            TextField("Имя (≤ 20)", text: limited)
        }
    }

    // ========================================================================
    // 4. ВЗАИМОДЕЙСТВИЕ @State + @Observable + @Bindable
    // ========================================================================
    //
    //  Роль View                     | Что писать
    //  ------------------------------|--------------------------------------
    //  Создаёт и владеет моделью     | @State private var model = Model()
    //  Только читает модель          | let model: Model   (или var)
    //  Нужны $-биндинги к модели     | @Bindable var model: Model
    //  Модель из окружения           | @Environment(Model.self) + локальный @Bindable
    //  Простое значение от родителя  | @Binding var value: T
    //  Значение, созданное тут       | @State private var value = ...
    //
    //  Поток данных (однонаправленный):
    //    Состояние (владелец @State)
    //        │ вниз: ссылка/let/@Bindable
    //        ▼
    //    Дочерняя View ──(пользователь изменил TextField)──▶ Binding.set
    //        │                                                  │
    //        └────────── Observation уведомляет ◀───────────────┘
    //
    // Золотое правило: объект ОДНОГО владельца (@State) может быть передан
    // многим View; создавать модель во второй раз в ребёнке — ошибка.

    // ========================================================================
    // 5. PRODUCTION-ПРИМЕР: редактирование профиля с черновиком
    // ========================================================================
    //
    // Требование продукта: пользователь правит профиль; "Отмена" не должна
    // менять сохранённые данные; "Сохранить" отправляет на сервер.
    // Решение: Domain-модель — struct (иммутабельный снимок), редактируем
    // КОПИЮ в @Observable-черновике (draft), на save собираем struct обратно.

    /// Domain: значение. Sendable, Equatable (для проверки "есть изменения").
    struct UserInfo: Equatable, Sendable {
        var name: String
        var bio: String
        var isPublic: Bool
    }

    protocol ProfileRepository: Sendable {
        func save(_ info: UserInfo) async throws
    }
    struct StubProfileRepository: ProfileRepository { func save(_ info: UserInfo) async throws {} }

    @MainActor
    @Observable
    final class ProfileEditorModel {
        // Редактируемые поля — то, на что смотрят $-биндинги
        var name: String
        var bio: String
        var isPublic: Bool

        private(set) var isSaving = false
        private(set) var errorMessage: String?

        @ObservationIgnored private let original: UserInfo
        @ObservationIgnored private let repository: any ProfileRepository
        @ObservationIgnored var onFinish: (() -> Void)?     // выход к Coordinator

        init(info: UserInfo, repository: any ProfileRepository) {
            self.original = info
            self.name = info.name; self.bio = info.bio; self.isPublic = info.isPublic
            self.repository = repository
        }

        // Снимок текущих полей как значение домена
        private var current: UserInfo { UserInfo(name: name, bio: bio, isPublic: isPublic) }

        var hasChanges: Bool { current != original }
        var canSave: Bool { hasChanges && !name.trimmingCharacters(in: .whitespaces).isEmpty && !isSaving }

        func save() async {
            guard canSave else { return }
            isSaving = true; errorMessage = nil
            defer { isSaving = false }
            do {
                try await repository.save(current)     // Sendable-значение пересекает границу
                onFinish?()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        func cancel() { onFinish?() }                   // original не тронут
    }

    struct ProfileEditorView: SwiftUI.View {
        @Bindable var model: ProfileEditorModel          // владелец — Coordinator/родитель

        var body: some SwiftUI.View {
            Form {
                TextField("Имя", text: $model.name)
                TextField("О себе", text: $model.bio)
                Toggle("Публичный", isOn: $model.isPublic)
                if let message = model.errorMessage { Text(message).foregroundStyle(.red) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { model.cancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { Task { await model.save() } }
                        .disabled(!model.canSave)
                }
            }
        }
    }

    // ========================================================================
    // 6. АРХИТЕКТУРНЫЙ АНАЛИЗ, ОШИБКИ, BEST PRACTICES
    // ========================================================================
    //
    // ИСПОЛЬЗУЙ @Bindable:
    //  - дочерняя View редактирует поля чужой @Observable-модели через
    //    TextField/Toggle/Picker/Slider/Stepper
    //  - модель пришла из @Environment, а нужны $-биндинги (локальный @Bindable)
    //  - строка списка редактирует свой элемент
    //
    // НЕ НУЖЕН:
    //  - модель только читается -> `let model`
    //  - View владеет моделью (@State): `$model.field` работает без @Bindable
    //  - нужен биндинг на простое значение родителя -> @Binding
    //  - модель — struct -> @State/@Binding (Bindable только для class)
    //
    // ПЛЮСЫ: чистый $-синтаксис, лёгкая обёртка (нет подписок/хранилища),
    //   сочетается с гранулярной Observation, поддерживает вложенные пути.
    // МИНУСЫ: iOS 17+; только @Observable-классы; нет защиты от прямой
    //   записи в любое публичное свойство (инкапсуляция — через private(set)
    //   и черновик).
    //
    // ОШИБКИ:
    //  1. @Bindable на объект, не являющийся @Observable — не скомпилируется.
    //  2. Путают с @State: @Bindable НЕ создаёт и не сохраняет объект. Создание
    //     `@Bindable var model = Model()` в View пересоздаёт модель при каждом
    //     пересоздании View — используй @State для владения.
    //  3. Делают @Bindable private и не могут инициализировать через init.
    //  4. Биндинг прямо на хранимую доменную модель -> "Отмена" невозможна,
    //     каждое нажатие клавиши уже изменило оригинал. Решение — черновик.
    //  5. Мутации не на main: Binding.set вызывается на main, но модель без
    //     @MainActor может быть изменена из фона -> гонка.
    //  6. Запись валидации в View (`if text.count > 20`) вместо модели/Binding.
    //
    // BEST PRACTICES:
    //  - владелец — @State выше по дереву; вниз — @Bindable/let
    //  - редактируй черновик, коммить значением (struct) по "Сохранить"
    //  - инварианты и производные (canSave) — в модели, не во View
    //  - минимальные модели на экран (в строке списка — своя модель/элемент)
    //  - UI-модель @MainActor; доменные значения Sendable

    // ========================================================================
    // 7. СВЯЗЬ С ДРУГИМИ МЕХАНИЗМАМИ
    // ========================================================================
    //  @State/@Observable: см. State_Explanation, Observable_Explanation.
    //  Clean Architecture: Presentation редактирует черновик, Domain получает
    //   валидное struct-значение; репозиторий скрыт протоколом.
    //  SOLID: SRP — View рисует, Model хранит/проверяет; DIP — репозиторий
    //   через протокол; OCP — новые поля добавляются в модель и форму.
    //  Concurrency: save() async на @MainActor, сетевая часть вне main;
    //   пересечение границ — только Sendable-значения (UserInfo).
    //  Combine: при необходимости debounce на ввод — через Task/AsyncStream
    //   или Combine-подписку на отдельное свойство.

    @MainActor
    static func run() async {
        let model = ProfileEditorModel(
            info: UserInfo(name: "Элшод", bio: "", isPublic: false),
            repository: StubProfileRepository()
        )
        model.name = "Элшод Ш."
        print(model.hasChanges)       // true
        await model.save()
    }
}
