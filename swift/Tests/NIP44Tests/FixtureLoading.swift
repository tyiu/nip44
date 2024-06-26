//
//  FixtureLoading.swift
//  
//
//  Created by Joel Klabo on 5/24/23.
//

import Foundation

enum FixtureLoadingError: Error {
    case missingFile
}

protocol FixtureLoading {}
extension FixtureLoading {

    func loadFixtureData(_ filename: String) throws -> Data {
        // Construct the URL for the fixtures directory.
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: filename, withExtension: "json", subdirectory: "Fixtures") else {
            throw FixtureLoadingError.missingFile
        }
        // Load the data from the file.
        return try Data(contentsOf: url)
    }

    func decodeFixture<T: Decodable>(filename: String) throws -> T {
        let data = try loadFixtureData(filename)
        return try JSONDecoder().decode(T.self, from: data)
    }

}

final class FixtureLoader: FixtureLoading {
    static let shared = FixtureLoader()
}
