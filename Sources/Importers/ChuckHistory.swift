//
//  ChuckHistory.swift
//
//
//  Input: for use with XXXX1234_Transactions_YYYYMMDD-HHMMSS.CSV from Schwab Brokerage Services
//
//  Output: supports openalloc/history schema
//
// Copyright 2021 FlowAllocator LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

import SwiftCSV

import AllocData

class ChuckHistory: FINporter {
    override var name: String { "Chuck History" }
    override var id: String { "chuck_history" }
    override var description: String { "Detect and decode account history export files from Schwab, for sale and purchase info." }
    override var sourceFormats: [AllocFormat] { [.CSV] }
    override var outputSchemas: [AllocSchema] { [.allocTransaction] }
    
    internal static let headerRE = #"""
    "Transactions\s+for .+? as of .+"
    "Date","Action","Symbol","Description","Quantity","Price","Fees & Comm","Amount",
    """#
    
    internal static let accountBlockRE = #"""
    (?:"Transactions\s+for .+? as of .+")
    "Date","Action","Symbol","Description","Quantity","Price","Fees & Comm","Amount",
    (?:.+(\n|\Z))+
    """#
    
    internal static let csvRE = #"""
    "Date","Action","Symbol","Description","Quantity","Price","Fees & Comm","Amount",
    (?:.+(\n|\Z))+
    """#
    
    override func detect(dataPrefix: Data) throws -> DetectResult {
        guard let str = FINporter.normalizeDecode(dataPrefix),
              str.range(of: ChuckHistory.headerRE,
                        options: .regularExpression) != nil
        else {
            return [:]
        }
        
        return outputSchemas.reduce(into: [:]) { map, schema in
            map[schema, default: []].append(.CSV)
        }
    }
    
    override open func decode<T: AllocBase>(_ type: T.Type,
                                            _ data: Data,
                                            rejectedRows: inout [T.RawRow],
                                            inputFormat _: AllocFormat? = nil,
                                            outputSchema: AllocSchema? = nil,
                                            url: URL? = nil,
                                            defTimeOfDay: String? = nil,
                                            defTimeZone: String? = nil,
                                            timestamp: Date? = nil) throws -> [T.DecodedRow] {
        guard var str = FINporter.normalizeDecode(data) else {
            throw FINporterError.decodingError("unable to parse data")
        }
        
        var items = [T.DecodedRow]()
        
        // one block per account expected
        while let range = str.range(of: ChuckHistory.accountBlockRE,
                                    options: .regularExpression) {
            let block = str[range]
            
            // first line has the account ID
            let accountID: String? = {
                let _range = block.lineRange(for: ..<block.startIndex)
                let rawStr = block[_range].trimmingCharacters(in: .whitespacesAndNewlines)
                return ChuckHistory.parseAccountID(rawStr)
            }()
            
            if let _accountID = accountID,
               let csvRange = block.range(of: ChuckHistory.csvRE,
                                          options: .regularExpression) {
                let csvStr = block[csvRange]
                let delimitedRows = try CSV(string: String(csvStr)).namedRows
                let nuItems = try decodeDelimitedRows(delimitedRows: delimitedRows,
                                                      accountID: _accountID,
                                                      defTimeOfDay: defTimeOfDay,
                                                      defTimeZone: defTimeZone,
                                                      rejectedRows: &rejectedRows)
                items.append(contentsOf: nuItems)
            }
            
            str.removeSubrange(range) // discard blocks as they are consumed
        }
        
        return items
    }
    
    internal func decodeDelimitedRows(delimitedRows: [AllocBase.RawRow],
                                      accountID: String,
                                      defTimeOfDay: String? = nil,
                                      defTimeZone: String? = nil,
                                      rejectedRows: inout [AllocBase.RawRow]) throws -> [AllocBase.DecodedRow] {
        
        delimitedRows.reduce(into: []) { decodedRows, delimitedRows in
            
            guard let rawAction = MTransaction.parseString(delimitedRows["Action"]),
                  let action = MTransaction.Action.getDecoded(rawAction: rawAction),
                  let rawDate = delimitedRows["Date"],
                  let transactedAt = parseChuckMMDDYYYY(rawDate, defTimeOfDay: defTimeOfDay, defTimeZone: defTimeZone),
                  let amount = MTransaction.parseDouble(delimitedRows["Amount"])
            else {
                rejectedRows.append(delimitedRows)
                return
            }
            
            var decodedRow: AllocBase.DecodedRow = [
                MTransaction.CodingKeys.action.rawValue: action,
                MTransaction.CodingKeys.transactedAt.rawValue: transactedAt,
                MTransaction.CodingKeys.accountID.rawValue: accountID,
                MTransaction.CodingKeys.lotID.rawValue: "",
            ]
            
            switch action {
            case .buy, .sell:
                guard let symbol = MTransaction.parseString(delimitedRows["Symbol"]),
                      let rawQuantity = MTransaction.parseDouble(delimitedRows["Quantity"]),
                      let sharePrice = MTransaction.parseDouble(delimitedRows["Price"])
                else {
                    rejectedRows.append(delimitedRows)
                    return
                }
                
                decodedRow[MTransaction.CodingKeys.securityID.rawValue] = symbol
                decodedRow[MTransaction.CodingKeys.sharePrice.rawValue] = sharePrice
                
                /// AllocData uses sign on shareCount to determine whether sale or purchase
                let shareCount: Double = {
                    switch action {
                    case .buy:
                        return rawQuantity
                    case .sell:
                        return -1 * rawQuantity
                    default:
                        return 0
                    }
                }()

                decodedRow[MTransaction.CodingKeys.shareCount.rawValue] = shareCount
                
            case .transfer:
                guard let rawSymbol = MTransaction.parseString(delimitedRows["Symbol"]),
                      rawSymbol.count > 0
                else {
                    rejectedRows.append(delimitedRows)
                    return
                }
                
                if rawSymbol == "NO NUMBER" {
                    // it's probably cash
                    decodedRow[MTransaction.CodingKeys.shareCount.rawValue] = amount
                    decodedRow[MTransaction.CodingKeys.sharePrice.rawValue] = 1.0
                    decodedRow[MTransaction.CodingKeys.securityID.rawValue] = ""
                } else {
                    guard let quantity = MTransaction.parseDouble(delimitedRows["Quantity"]),
                          quantity > 0
                    else {
                        rejectedRows.append(delimitedRows)
                        return
                    }
                    let sharePrice = amount / quantity
                    decodedRow[MTransaction.CodingKeys.shareCount.rawValue] = quantity
                    decodedRow[MTransaction.CodingKeys.sharePrice.rawValue] = sharePrice
                    decodedRow[MTransaction.CodingKeys.securityID.rawValue] = rawSymbol
                }
                
            case .dividendIncome:
                guard let rawSymbol = MTransaction.parseString(delimitedRows["Symbol"]),
                      rawSymbol.count > 0
                else {
                    rejectedRows.append(delimitedRows)
                    return
                }
                
                decodedRow[MTransaction.CodingKeys.shareCount.rawValue] = amount
                decodedRow[MTransaction.CodingKeys.sharePrice.rawValue] = 1.0
                decodedRow[MTransaction.CodingKeys.securityID.rawValue] = rawSymbol

            case .interestIncome, .miscIncome:
                decodedRow[MTransaction.CodingKeys.shareCount.rawValue] = amount
                decodedRow[MTransaction.CodingKeys.sharePrice.rawValue] = 1.0
            }
            
//            let rawSymbol = MTransaction.parseString(delimitedRows["Symbol"]),
//            let rawQuantity = MTransaction.parseDouble(delimitedRows["Quantity"]),
//            let sharePrice = MTransaction.parseDouble(delimitedRows["Price"]),
//            let rawDate = delimitedRows["Date"],
//            let transactedAt = parseChuckMMDDYYYY(rawDate, defTimeOfDay: defTimeOfDay, defTimeZone: defTimeZone)
            
            // optional values
            
//            let shareCount: Double = {
//                switch rawAction {
//                case "Buy":
//                    return rawQuantity
//                case "Sell":
//                    return -1 * rawQuantity
//                default:
//                    return 0
//                }
//            }()
//            decodedRows.append([
//                MTransaction.CodingKeys.action.rawValue: action,
////                MTransaction.CodingKeys.transactedAt.rawValue: transactedAt,
////                MTransaction.CodingKeys.accountID.rawValue: accountID,
////                MTransaction.CodingKeys.securityID.rawValue: rawSymbol,
//                MTransaction.CodingKeys.lotID.rawValue: lotID,
////                MTransaction.CodingKeys.shareCount.rawValue: shareCount,
////                MTransaction.CodingKeys.sharePrice.rawValue: sharePrice,
//                //MTransaction.CodingKeys.realizedGainShort.rawValue: nil,
//                //MTransaction.CodingKeys.realizedGainLong.rawValue: nil,
//            ])

            
            decodedRows.append(decodedRow)
        }
    }
    
    
    
    // parse ""Transactions  for account XXXX-1234 as of 09/26/2021 22:00:26 ET"" to extract "XXXX-1234"
    internal static func parseAccountID(_ rawStr: String) -> String? {
        let pattern = #""Transactions\s+for account ([A-Z0-9-_]+) as of.+""#
        guard let captured = rawStr.captureGroups(for: pattern, options: .caseInsensitive),
              captured.count == 1
        else { return nil }
        return captured[0]
    }
}

extension MTransaction.Action {
    static func getDecoded(rawAction: String) -> MTransaction.Action? {
        switch rawAction {
        case "Buy":
            return .buy
        case "Sell":
            return .sell
        case "Security Transfer":
            return .transfer
        case "Cash Dividend":
            return .dividendIncome
        case "Bank Interest":
            return .interestIncome
        case "Promotional Award":
            return .miscIncome
        default:
            return nil
        }
    }
}
