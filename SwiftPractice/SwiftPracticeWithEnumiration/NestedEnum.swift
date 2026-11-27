//
//  NestedEnum.swift
//  SwiftPractice
//
//  Created by Sharif on 27/11/26.
//
enum Resturant {
    enum Menu {
        case appetizers([String])
        case entries([String])
        case desserts([String])
    }
  case name(String)
  case location(String)
  case rating(Double)
  case menu(Menu)
}
    
let menu: Resturant.Menu = .entries(["Chicken","Beef"])
