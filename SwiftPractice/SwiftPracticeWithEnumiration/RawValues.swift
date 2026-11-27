//
//  RawValues.swift
//  SwiftPractice
//
//  Created by Sharif on 27/11/26.
//

// buyerda rav value type int
enum WeekDay : Int {
    case sunday = 1
    case monday
    case thuesday
    case wendesday
    case thursday
    case friday
    case saturday
}

//print(Weekday.sunday.rawValue)
enum HttStatusCode: String {
    case ok = "200"
    case noutFound = "404"
    case badRequest = "400"
}

let day = 3

/*if let weekday = WeekDay(rawValue: day){
 print(weekday)
}*/
//print(weekday)
enum UserRole: String,Codable {
    case admin = "admin"
    case user = "user"
}
let userRole = UserRole.admin
//let jsonData = try? JSONEncoder().encode(UserRole)
//let decodeuser = try JSONDecoder().decode(UserRole.self, from:jsonData)
//print( decodeuser.rawValue)
