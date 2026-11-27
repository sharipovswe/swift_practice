//
//  EnumWithStaticFunctions.swift
//  SwiftPractice
//
//  Created by Sharif on 27/11/26.
//

enum HTTPMethod{
    case get
    case post
    case put
    case delete
    var title: String {
        switch self {
        case .get:
            return "GET"
        case .post:
            return "POST"
        case .put:
            return "PUT"
        case .delete:
            return "DELETE"
        }
    }
    static func allMethods()->[HTTPMethod]{
        return [.get,.post,.put,.delete]
    }
}
let allMethods = HTTPMethod.allMethods()

