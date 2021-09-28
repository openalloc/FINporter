//
//  AllocSmart.swift
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

class AllocSmart: FINporter {
    // extract up to three different strategies from data

    // map to allocat names
    private static let assetClassMap: [String: MAsset.StandardID] = [
        "US Aggregate Bonds": .bond,
        "Cash": .cash,
        "Commodities": .cmdty,
        "US Corporate Bonds": .corpbond,
        "Emerging Market Equities": .em,
        "Emerging Market Bonds": .embond,
        "Europe Equities": .europe,
        "Global Real Estate": .globre,
        "Gold": .gold,
        "High Yield Bonds": .hybond,
        "Int-Term US Treasuries": .itgov,
        "International Equities": .intl,
        "Intl Aggregate Bonds": .intlbond,
        "International Treasuries": .intlgov,
        "International Real Estate": .intlre,
        "Intl Small Cap Equities": .intlsc,
        "International Value": .intlval,
        "Japan Equities": .japan,
        "S&P 500": .lc,
        "US Large Cap Growth": .lcgrow,
        "US Large Cap Value": .lcval,
        "Long-Term US Treasuries": .ltgov,
        "US Momentum": .momentum,
        "Pacific Equities": .pacific,
        "US Real Estate": .re,
        "US Mortgage REITs": .remort,
        "US Small Cap Equities": .sc,
        "US Small Cap Growth": .scgrow,
        "US Small Cap Value": .scval,
        "Short-Term US Treasuries": .stgov,
        "TIPS": .tips,
        "Nasdaq 100": .tech,
        "US Total Market": .total,
    ]

    override var name: String { "Alloc Smart" }
    override var id: String { "alloc_smart" }
    override var description: String { "Detect and decode export files from Allocate Smartly." }
    override var sourceFormats: [AllocFormat] { [.CSV] }
    override var outputSchemas: [AllocSchema] { [.allocAllocation] }

    internal static let headerRE = #"""
    AllocateSmart.*
    Model Portfolio.*
    Export time:.*

    """#

    internal static let blockRE = #"""
    .+
    Account Size, \d+.*
    Asset,Description,.+
    (?:.+[\n\r])+
    """#
    
    internal static let csvRE = #"Asset,Description,(?:.+(\r?\n|\Z))+"#

    override func detect(dataPrefix: Data) throws -> DetectResult {
        guard let str = String(data: dataPrefix, encoding: .utf8),
              str.range(of: AllocSmart.headerRE,
                        options: .regularExpression) != nil
        else {
            return [:]
        }

        return outputSchemas.reduce(into: [:]) { map, schema in
            map[schema, default: []].append(.CSV)
        }
    }

    override open func decode<T: AllocBase>(_: T.Type,
                                            _ data: Data,
                                            rejectedRows: inout [T.Row],
                                            inputFormat _: AllocFormat? = nil,
                                            outputSchema _: AllocSchema? = nil,
                                            url _: URL? = nil,
                                            defTimeOfDay _: String? = nil,
                                            defTimeZone _: String? = nil,
                                            timestamp _: Date? = nil) throws -> [T.Row] {
        guard var str = FINporter.decode(data: data) else {
            throw FINporterError.decodingError("unable to parse data")
        }

        var items = [T.Row]()

        // returns first match to RE as Range<String.Index (nil if none)
        while let range = str.range(of: AllocSmart.blockRE, options: .regularExpression) {
            let block = str[range]

            // first line is the title
            let titleRange = block.lineRange(for: ..<block.startIndex)
            let strategyID = block[titleRange].trimmingCharacters(in: .whitespacesAndNewlines)

            if let csvRange = block.range(of: AllocSmart.csvRE, options: .regularExpression) {
                let csvStr = block[csvRange]
                let csv = try CSV(string: String(csvStr))

                for row in csv.namedRows {
                    // required values
                    guard let rawDescript = T.parseString(row["Description"]),
                          rawDescript.count > 0,
                          let assetID = AllocSmart.assetClassMap[rawDescript]?.rawValue,
                          let targetPct = T.parsePercent(row["Optimal Allocation"]),
                          targetPct >= 0
                    else {
                        rejectedRows.append(row)
                        continue
                    }

                    // optional values

                    items.append([
                        MAllocation.CodingKeys.strategyID.rawValue: strategyID,
                        MAllocation.CodingKeys.assetID.rawValue: assetID,
                        MAllocation.CodingKeys.targetPct.rawValue: targetPct,
                        MAllocation.CodingKeys.isLocked.rawValue: false
                    ])
                }
            }

            str.removeSubrange(range)
        }

        return items // as! [T]
    }
}
