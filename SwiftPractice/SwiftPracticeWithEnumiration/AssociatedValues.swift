//
//  AssociatedValues.swift
//  SwiftPractice
//
//  Created by Sharif on 27/11/26.
//

enum Request {
    case get(String)
    case post(String,String)
}
func makeRequest(_ request: Request){
    switch request {
    case .get(let url):
        print(url)
    case .post(let url,let parameters):
        print(url,parameters)
    }
}
enum Result<T>{
    case succes(T)
    case failure(Error)
}
func fetchData(completion:((Result<String>)->Void)){
    
}
