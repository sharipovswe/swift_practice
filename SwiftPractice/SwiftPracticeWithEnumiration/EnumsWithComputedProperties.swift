//
//  EnumsWithComputedProperties.swift
//  SwiftPractice
//
//  Created by Sharif on 27/11/26.
//
enum WeatHer {
    case sunny(Double)
    case rainy(Double)
    var isNiceWeather: Bool{
        switch self {
        case .sunny(let temp):
            return temp > 0
        case .rainy(let rainfall):
            return rainfall < 0.5
        }
    }
}
 
let weather = WeatHer.sunny(80.5)
