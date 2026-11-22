//
//  main.swift
//  SwiftPractice
//
//  Created by Sharif on 20/11/26.
//

import Foundation

print("Hello, World!")

// MARK 1 : Перемение
// смотите здес подерживате написание камел кейс синтаксис

var userName: String = "Олег"
print(userName)
userName = "Иван"
print(userName)
// если говорим про констание мы обявим этот варебле
let age: Int = 23
// MARK 2 : Типы данных
var price: Int = 25
var secondPrice: Int = 40
let login: String = "mail.com"
var isLogin: Bool = true

if isLogin {
    print("Привет мир как ты чувак")
} else {
    print("сколко лет сколко зым")
}
var pi: Float = 3.14
var e: Double = 2.71
// Double два раза болшье у Float  та
// Swift это строгий типизирование язык програмирование

// MARK 3 : Опционалы
var packet: String?
var air: Int? = nil
var userLogin: String?
var user: String? = " дядя Шариф "
var userAge: Int? = 23

userLogin = "Администратор"
print("\(userLogin) \(user)")
// 1 optional binding
if let log = userLogin {
    print("user login =\(userLogin)")
} else {
    print("user login = nil")
}
if let newUserAge = userAge {
    let res = age + newUserAge
}
if userAge != nil {
    let res = age + userAge!
}
let res = age + (userAge ?? 0)
print("hello nigga -> \(res)")
// 2 force unwrap

print(userAge!)

// MARK 4 : Массивы

var book: String = "Harry Potter"

var books: [String] = ["Harry Potter", "To Kill a Mokhinbird", "1984"]

books.append("Гнилой")
books.remove(at: 2)
print(books[2])
// print(books.first) print(books.last)
for book in books {
    if book == "Harry Potter" {
        print("find")
    } else {
        print(books)
    }
}
// MARK 5 : Словари / Dictionary

var userFirst: [String: String] = [
    "name": "Шариф", "age": "23", "city": "Tашкент",
]
var userSecond: [String: String] = [
    "name": "Элшод", "age": "23", "city": "Tашкент",
]

var users: [[String: String]] = [userFirst, userSecond]

for item in userFirst {
    print(item.key)
    print(item.value)
}
// MARK 6 : Функции
// 1 - ничего не принимает и не возращает
func sayHello() {
    var name: String = "Шариф"
    print("Привет \(name)!!")
}
/*func save(){
 var date = Date()
   //-> send request
}*/

// 2 - принимает дание но ничего не возрашает
// мы можем написат в функцию но не надо это в обичном  let name: String,let age: Int ,let login: String
func setUserData(name: String, age: Int, login: String) {
    if age > 18 {
        if login == "аdmin" {
            print("что - то админское ")
            print(name)
        } else {
            print("Ты не админ чувак \(name)")
            // print(name);
        }
    } else {
        print("Сорян")
    }
}

setUserData(name: "Элшод", age: 23, login: "аdmin")
setUserData(name: "Азизбек", age: 13, login: "аdmin")
setUserData(name: "Федя", age: 23, login: "manager")

//3 - принимает дание и возращает ответ

func loginInApp(login: String, password: String) -> Bool {
    if login == "admin", password == "qwerty" {
        return true
    } else {
        return false
    }
}
let isAppLogin = loginInApp(login: "admin", password: "qwert")
if isAppLogin {
    print("Авторизовались")
} else {
    print("не авторизовались")
}

// ничего не принимает но возращает
func checkAuth() -> Bool {
    let login: String = "admin"
    //->req
    return true
}
func getUserData() -> [String: String] {
    //sfdsfdsfdsfd
    return ["name": "user"]
}
func getUserData() {

}
func getUserData(id: Int) {

}
// MARK 7 : enum
// Enum (enumeration, перечисление) — это тип с заранее известным, конечным набором значений. Переменная такого типа может быть только одним из этих вариантов. Всё остальное компилятор не пропустит.

func calcFirst(a: Float, b: Float, opr: Character) -> Float {
    if opr == "+" {
        return a + b
    } else if opr == "-" {
        return a - b
    } else if opr == "*" {
        return a * b
    } else if opr == "/" {
        return a / b
    } else {
        return 0
    }
}
let r = calcFirst(a: 12, b: 900, opr: "*")
print("res->  \(r)")
enum CalcOperation {
    case plus
    case minus
    case division
    case multipl
}
// кстати мы можем написат вот такиме образом в обичноме виде нет разнице  case plus, minus,  division,multipl
func calcSecond(a: Float, b: Float, opr: CalcOperation ) -> Float{
    switch opr{
    case .plus:
        return a + b
    case .minus:
        return a - b
    case .division:
        return a/b
    case .multipl:
        return a * b
    }
}
let x = calcSecond(a: 120, b:12, opr: .division)
print("xyz - > \(x)")
// Raw values (сырые значения) в enum должны быть уникальными.
// Если два case получат одинаковое значение, компилятор выдаст ошибку
// "Raw value for enum case is not unique" ещё до запуска программы.
enum WorldSide: String {
    // Если не задать значение явно (например, просто `case east`),
    // тип raw value всё равно останется String: его задаёт тип,
    // указанный после двоеточия (`: String`).
    // Значением автоматически станет имя самого case:
    // WorldSide.east.rawValue == "east".
    case east = "Восток"
    case west = "Запад"
    case north = "Север"
    case south = "Юг"
}

// Для Int raw values автоматическое значение работает иначе:
// первый case без значения получает 0, а каждый следующий
// получает значение предыдущего + 1.
enum NumberLetsGo: Int {
    case first          // 0, автоматически
    case second = 100   // 100, задано явно
    case last           // 101, автоматически (100 + 1)
}

//NumberLetsGo.first.rawValue   // 0
//NumberLetsGo.second.rawValue  // 100
//NumberLetsGo.last.rawValue    // 101
let worldSide :  WorldSide = .east
print(worldSide.rawValue)
print(worldSide.hashValue)
enum ReqError : Error {
    case noutFound
    case noData
    case longReq
}
// MARK 8 : Классы
//btn - UIButton
//рефренс тайпе валуе тайп
// 1- send req
// 2- store data
// 3- valid data

class NetworkService {

    // method - функции
    // value - переменные

    var userData: [String] = []
    var url: String
    var name: String = ""

    // init вызывается во время создания экземпляра этого класса.
    // Он первым делом инициализирует свойства объекта.
    init(userData: [String], url: String) {
        self.userData = userData
        self.url = url
    }

    func sendRequest() {
        print("send request to url \(url)")
    }
}

let network = NetworkService(
    userData: ["userfirst"],
    url: "https://google.com"
)

network.name = "Элшод"

network.sendRequest()
class View{
    var view:String
    var date:Date
    init(view: String, date: Date) {
        self.view = view
        self.date = date
    }
    func addSubView(){
        print("addSubview")
    }
    func removeSubView(){
        print("removeSubView")
    }
}
// MARK 9 : Структуры
// Подробный разбор: Structures/Structures_Explanation.swift  (StructuresLesson)

// MARK 10 : Протоколы
// Подробный разбор: Protocols/Protocols_Explanation.swift  (ProtocolsLesson)

// MARK 11 : Обработки ошибок
// Подробный разбор: ErrorHandling/ErrorHandling_Explanation.swift  (ErrorHandlingLesson)

// MARK 12 : Клоужеры
// Подробный разбор: Closures/Closures_Explanation.swift  (ClosuresLesson)
//
// Дополнительные темы (по одному файлу на механизм):
//  Concurrency/Sendable_Explanation.swift      — Sendable, @Sendable, nonisolated, where T: Sendable
//  Concurrency/Concurrency_Explanation.swift   — DispatchQueue, Task, @escaping, @MainActor
//  Concurrency/AsyncStream_Explanation.swift   — AsyncStream.makeStream(), consumer, SDKListener
//  SwiftUI/State_Explanation.swift             — @State
//  SwiftUI/Observable_Explanation.swift        — @Observable
//  SwiftUI/Bindable_Explanation.swift          — @Bindable
//  Combine/AnyPublisher_Explanation.swift      — AnyPublisher, type erasure
//
// Запуск любого урока из main.swift (пример):
//   Task { await StructuresLesson.run() }
