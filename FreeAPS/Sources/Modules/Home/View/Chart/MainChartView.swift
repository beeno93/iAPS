import Algorithms
import SwiftDate
import SwiftUI

private enum PredictionType: Hashable {
    case iob
    case cob
    case zt
    case uam
}

struct MainChartView: View {
    private enum Config {
        static let screenHours = 5
        static let basalHeight: CGFloat = 60
        static let topYPadding: CGFloat = 20
        static let bottomYPadding: CGFloat = 50
        static let minAdditionalWidth: CGFloat = 150
        static let maxGlucose = 450
        static let minGlucose = 70
        static let yLinesCount = 5
        static let bolusSize: CGFloat = 8
        static let bolusScale: CGFloat = 8
    }

    @Binding var glucose: [BloodGlucose]
    @Binding var suggestion: Suggestion?
    @Binding var tempBasals: [PumpHistoryEvent]
    @Binding var boluses: [PumpHistoryEvent]
    @Binding var hours: Int
    @Binding var maxBasal: Decimal
    @Binding var basalProfile: [BasalProfileEntry]
    @Binding var tempTargets: [TempTarget]
    let units: GlucoseUnits

    @State var didAppearTrigger = false
    @State private var glucoseDots: [CGRect] = []
    @State private var predictionDots: [PredictionType: [CGRect]] = [:]
    @State private var bolusDots: [CGRect] = []
    @State private var bolusPath = Path()
    @State private var bolusLabels = AnyView(EmptyView())
    @State private var tempBasalPath = Path()
    @State private var regularBasalPath = Path()
    @State private var tempTargetsPath = Path()

    private var dateDormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }

    private var glucoseFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }

    private var basalFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        return formatter
    }

    private var bolusFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumIntegerDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.decimalSeparator = "."
        return formatter
    }

    // MARK: - Views

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Y grid
                Path { path in
                    let range = glucoseYRange(fullSize: geo.size)
                    let step = (range.maxY - range.minY) / CGFloat(Config.yLinesCount)
                    for line in 0 ... Config.yLinesCount {
                        path.move(to: CGPoint(x: 0, y: range.minY + CGFloat(line) * step))
                        path.addLine(to: CGPoint(x: geo.size.width, y: range.minY + CGFloat(line) * step))
                    }
                }.stroke(Color.secondary, lineWidth: 0.2)

                ScrollView(.horizontal, showsIndicators: false) {
                    ScrollViewReader { scroll in
                        ZStack(alignment: .top) {
                            tempTargetsView(fullSize: geo.size)
                            basalChart(fullSize: geo.size)
                            mainChart(fullSize: geo.size).id("End")
                                .onChange(of: glucose) { _ in
                                    scroll.scrollTo("End", anchor: .trailing)
                                }
                                .onChange(of: suggestion) { _ in
                                    scroll.scrollTo("End", anchor: .trailing)
                                }
                                .onChange(of: tempBasals) { _ in
                                    scroll.scrollTo("End", anchor: .trailing)
                                }
                                .onAppear {
                                    // add trigger to the end of main queue
                                    DispatchQueue.main.async {
                                        scroll.scrollTo("End", anchor: .trailing)
                                        didAppearTrigger = true
                                    }
                                }
                        }
                    }
                }
                // Y glucose labels
                ForEach(0 ..< Config.yLinesCount + 1) { line -> AnyView in
                    let range = glucoseYRange(fullSize: geo.size)
                    let yStep = (range.maxY - range.minY) / CGFloat(Config.yLinesCount)
                    let valueStep = Double(range.maxValue - range.minValue) / Double(Config.yLinesCount)
                    let value = round(Double(range.maxValue) - Double(line) * valueStep) *
                        (units == .mmolL ? Double(GlucoseUnits.exchangeRate) : 1)

                    return Text(glucoseFormatter.string(from: value as NSNumber)!)
                        .position(CGPoint(x: geo.size.width - 12, y: range.minY + CGFloat(line) * yStep))
                        .font(.caption2)
                        .asAny()
                }
            }
        }
    }

    private func basalChart(fullSize: CGSize) -> some View {
        ZStack {
            tempBasalPath.fill(Color.blue)
            tempBasalPath.stroke(Color.blue, lineWidth: 1)
            regularBasalPath.stroke(Color.yellow, lineWidth: 1)
            Text(lastBasalRateString)
                .foregroundColor(.blue)
                .font(.caption2)
                .position(CGPoint(x: lastBasalPoint(fullSize: fullSize).x + 30, y: Config.basalHeight / 2))
        }
        .drawingGroup()
        .frame(width: fullGlucoseWidth(viewWidth: fullSize.width) + additionalWidth(viewWidth: fullSize.width))
        .frame(maxHeight: Config.basalHeight)
        .background(Color.secondary.opacity(0.1))
        .onChange(of: tempBasals) { _ in
            calculateBasalPoints(fullSize: fullSize)
        }
        .onChange(of: maxBasal) { _ in
            calculateBasalPoints(fullSize: fullSize)
        }
        .onChange(of: basalProfile) { _ in
            calculateBasalPoints(fullSize: fullSize)
        }
        .onChange(of: didAppearTrigger) { _ in
            calculateBasalPoints(fullSize: fullSize)
        }
    }

    private func mainChart(fullSize: CGSize) -> some View {
        Group {
            VStack {
                ZStack {
                    // X grid
                    Path { path in
                        for hour in 0 ..< hours + hours {
                            let x = firstHourPosition(viewWidth: fullSize.width) +
                                oneSecondStep(viewWidth: fullSize.width) *
                                CGFloat(hour) * CGFloat(1.hours.timeInterval)
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: fullSize.height - 20))
                        }
                    }
                    .stroke(Color.secondary, lineWidth: 0.2)
                    bolusView(fullSize: fullSize)
                    glucosePath(fullSize: fullSize)
                    predictions(fullSize: fullSize)
                }
                ZStack {
                    // X time labels
                    ForEach(0 ..< hours + hours) { hour in
                        Text(dateDormatter.string(from: firstHourDate().addingTimeInterval(hour.hours.timeInterval)))
                            .font(.caption)
                            .position(
                                x: firstHourPosition(viewWidth: fullSize.width) +
                                    oneSecondStep(viewWidth: fullSize.width) *
                                    CGFloat(hour) * CGFloat(1.hours.timeInterval),
                                y: 10.0
                            )
                            .foregroundColor(.secondary)
                    }
                }.frame(maxHeight: 20)
            }
        }
        .frame(width: fullGlucoseWidth(viewWidth: fullSize.width) + additionalWidth(viewWidth: fullSize.width))
    }

    private func glucosePath(fullSize: CGSize) -> some View {
        Path { path in
            for rect in glucoseDots {
                path.addEllipse(in: rect)
            }
        }
        .fill(Color.green)
        .onChange(of: glucose) { _ in
            calculateGlucoseDots(fullSize: fullSize)
        }
        .onChange(of: didAppearTrigger) { _ in
            calculateGlucoseDots(fullSize: fullSize)
        }
    }

    private func bolusView(fullSize: CGSize) -> some View {
        ZStack {
            bolusPath
                .fill(Color.blue)
            bolusPath
                .stroke(Color.primary, lineWidth: 0.5)

            ForEach(bolusDots.indexed(), id: \.1.minX) { index, rect -> AnyView in
                let position = CGPoint(x: rect.midX, y: rect.maxY + 8)
                return Text(bolusFormatter.string(from: (boluses[index].amount ?? 0) as NSNumber)!).font(.caption2)
                    .position(position)
                    .asAny()
            }
        }
        .onChange(of: boluses) { _ in
            calculateBolusDots(fullSize: fullSize)
        }
        .onChange(of: didAppearTrigger) { _ in
            calculateBolusDots(fullSize: fullSize)
        }
    }

    private func tempTargetsView(fullSize: CGSize) -> some View {
        ZStack {
            tempTargetsPath
                .fill(Color.gray.opacity(0.5))
        }
        .onChange(of: glucose) { _ in
            calculateTempTargetsRects(fullSize: fullSize)
        }
        .onChange(of: tempTargets) { _ in
            calculateTempTargetsRects(fullSize: fullSize)
        }
        .onChange(of: didAppearTrigger) { _ in
            calculateTempTargetsRects(fullSize: fullSize)
        }
    }

    private func predictions(fullSize: CGSize) -> some View {
        Group {
            Path { path in
                for rect in predictionDots[.iob] ?? [] {
                    path.addEllipse(in: rect)
                }
            }.stroke(Color.blue)

            Path { path in
                for rect in predictionDots[.cob] ?? [] {
                    path.addEllipse(in: rect)
                }
            }.stroke(Color.yellow)

            Path { path in
                for rect in predictionDots[.zt] ?? [] {
                    path.addEllipse(in: rect)
                }
            }.stroke(Color.purple)

            Path { path in
                for rect in predictionDots[.uam] ?? [] {
                    path.addEllipse(in: rect)
                }
            }.stroke(Color.orange)
        }
        .onChange(of: suggestion) { _ in
            calculatePredictionDots(fullSize: fullSize, type: .iob)
            calculatePredictionDots(fullSize: fullSize, type: .cob)
            calculatePredictionDots(fullSize: fullSize, type: .zt)
            calculatePredictionDots(fullSize: fullSize, type: .uam)
        }
        .onChange(of: didAppearTrigger) { _ in
            calculatePredictionDots(fullSize: fullSize, type: .iob)
            calculatePredictionDots(fullSize: fullSize, type: .cob)
            calculatePredictionDots(fullSize: fullSize, type: .zt)
            calculatePredictionDots(fullSize: fullSize, type: .uam)
        }
    }

    // MARK: - Calculations

    private func calculateGlucoseDots(fullSize: CGSize) {
        glucoseDots = glucose.concurrentMap { value -> CGRect in
            let position = glucoseToCoordinate(value, fullSize: fullSize)
            return CGRect(x: position.x - 2, y: position.y - 2, width: 4, height: 4)
        }
    }

    private func calculateBolusDots(fullSize: CGSize) {
        bolusDots = boluses.map { value -> CGRect in
            let center = timeToInterpolatedPoint(value.timestamp.timeIntervalSince1970, fullSize: fullSize)
            let size = Config.bolusSize + CGFloat(value.amount ?? 0) * Config.bolusScale
            return CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        }
        bolusPath = Path { path in
            for rect in bolusDots {
                path.addEllipse(in: rect)
            }
        }
    }

    private func calculatePredictionDots(fullSize: CGSize, type: PredictionType) {
        let values: [Int] = { () -> [Int] in
            switch type {
            case .iob:
                return suggestion?.predictions?.iob ?? []
            case .cob:
                return suggestion?.predictions?.cob ?? []
            case .zt:
                return suggestion?.predictions?.zt ?? []
            case .uam:
                return suggestion?.predictions?.uam ?? []
            }
        }()

        var index = 0
        predictionDots[type] = values.map { value -> CGRect in
            let position = predictionToCoordinate(value, fullSize: fullSize, index: index)
            index += 1
            return CGRect(x: position.x - 2, y: position.y - 2, width: 4, height: 4)
        }
    }

    private func calculateBasalPoints(fullSize: CGSize) {
        let dayAgoTime = Date().addingTimeInterval(-1.days.timeInterval).timeIntervalSince1970
        let firstTempTime = (tempBasals.first?.timestamp ?? Date()).timeIntervalSince1970
        var lastTimeEnd = firstTempTime
        let firstRegularBasalPoints = findRegularBasalPoints(timeBegin: dayAgoTime, timeEnd: firstTempTime, fullSize: fullSize)
        let tempBasalPoints = firstRegularBasalPoints + tempBasals.chunks(ofCount: 2).map { chunk -> [CGPoint] in
            let chunk = Array(chunk)
            guard chunk.count == 2, chunk[0].type == .tempBasal, chunk[1].type == .tempBasalDuration else { return [] }
            let timeBegin = chunk[0].timestamp.timeIntervalSince1970
            let timeEnd = timeBegin + (chunk[1].durationMin ?? 0).minutes.timeInterval
            let rateCost = Config.basalHeight / CGFloat(maxBasal)
            let x0 = timeToXCoordinate(timeBegin, fullSize: fullSize)
            let y0 = Config.basalHeight - CGFloat(chunk[0].rate ?? 0) * rateCost
            let x1 = timeToXCoordinate(timeEnd, fullSize: fullSize)
            let y1 = Config.basalHeight
            let regularPoints = findRegularBasalPoints(timeBegin: lastTimeEnd, timeEnd: timeBegin, fullSize: fullSize)
            lastTimeEnd = timeEnd
            return regularPoints + [CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y1)]
        }.flatMap { $0 }
        tempBasalPath = Path { path in
            var yPoint: CGFloat = Config.basalHeight
            path.move(to: CGPoint(x: 0, y: yPoint))

            for point in tempBasalPoints {
                path.addLine(to: CGPoint(x: point.x, y: yPoint))
                path.addLine(to: point)
                yPoint = point.y
            }
            let lastPoint = lastBasalPoint(fullSize: fullSize)
            path.addLine(to: CGPoint(x: lastPoint.x, y: Config.basalHeight))
            path.addLine(to: CGPoint(x: 0, y: Config.basalHeight))
        }

        let endDateTime = dayAgoTime + 1.days.timeInterval + 6.hours.timeInterval
        let regularBasalPoints = findRegularBasalPoints(
            timeBegin: dayAgoTime,
            timeEnd: endDateTime,
            fullSize: fullSize
        )

        regularBasalPath = Path { path in
            var yPoint: CGFloat = Config.basalHeight
            path.move(to: CGPoint(x: -50, y: yPoint))

            for point in regularBasalPoints {
                path.addLine(to: CGPoint(x: point.x, y: yPoint))
                path.addLine(to: point)
                yPoint = point.y
            }
            path.addLine(to: CGPoint(x: timeToXCoordinate(endDateTime, fullSize: fullSize), y: yPoint))
        }
    }

    private func findRegularBasalPoints(timeBegin: TimeInterval, timeEnd: TimeInterval, fullSize: CGSize) -> [CGPoint] {
        guard timeBegin < timeEnd else {
            return []
        }
        let beginDate = Date(timeIntervalSince1970: timeBegin)
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: beginDate)

        let basalNormalized = basalProfile.map {
            (
                time: startOfDay.addingTimeInterval($0.minutes.minutes.timeInterval).timeIntervalSince1970,
                rate: $0.rate
            )
        } + basalProfile.map {
            (
                time: startOfDay.addingTimeInterval($0.minutes.minutes.timeInterval + 1.days.timeInterval).timeIntervalSince1970,
                rate: $0.rate
            )
        } + basalProfile.map {
            (
                time: startOfDay.addingTimeInterval($0.minutes.minutes.timeInterval + 2.days.timeInterval).timeIntervalSince1970,
                rate: $0.rate
            )
        }

        let basalTruncatedPoints = basalNormalized.windows(ofCount: 2)
            .compactMap { window -> CGPoint? in
                let window = Array(window)
                if window[0].time < timeBegin, window[1].time < timeBegin {
                    return nil
                }

                let rateCost = Config.basalHeight / CGFloat(maxBasal)
                if window[0].time < timeBegin, window[1].time >= timeBegin {
                    let x = timeToXCoordinate(timeBegin, fullSize: fullSize)
                    let y = Config.basalHeight - CGFloat(window[0].rate) * rateCost
                    return CGPoint(x: x, y: y)
                }

                if window[0].time >= timeBegin, window[0].time < timeEnd {
                    let x = timeToXCoordinate(window[0].time, fullSize: fullSize)
                    let y = Config.basalHeight - CGFloat(window[0].rate) * rateCost
                    return CGPoint(x: x, y: y)
                }

                return nil
            }

        return basalTruncatedPoints
    }

    private func lastBasalPoint(fullSize: CGSize) -> CGPoint {
        let lastBasal = Array(tempBasals.suffix(2))
        guard lastBasal.count == 2 else {
            return .zero
        }
        let endBasalTime = lastBasal[0].timestamp.timeIntervalSince1970 + (lastBasal[1].durationMin?.minutes.timeInterval ?? 0)
        let rateCost = Config.basalHeight / CGFloat(maxBasal)
        let x = timeToXCoordinate(endBasalTime, fullSize: fullSize)
        let y = Config.basalHeight - CGFloat(lastBasal[0].rate ?? 0) * rateCost
        return CGPoint(x: x, y: y)
    }

    private var lastBasalRateString: String {
        let lastBasal = Array(tempBasals.suffix(2))
        guard lastBasal.count == 2 else {
            return ""
        }
        let lastRate = lastBasal[0].rate ?? 0
        return (basalFormatter.string(from: lastRate as NSNumber) ?? "0") + " U/hr"
    }

    private func fullGlucoseWidth(viewWidth: CGFloat) -> CGFloat {
        viewWidth * CGFloat(hours) / CGFloat(Config.screenHours)
    }

    private func additionalWidth(viewWidth: CGFloat) -> CGFloat {
        guard let predictions = suggestion?.predictions,
              let deliveredAt = suggestion?.deliverAt,
              let last = glucose.last
        else {
            return Config.minAdditionalWidth
        }

        let iob = predictions.iob?.count ?? 0
        let zt = predictions.zt?.count ?? 0
        let cob = predictions.cob?.count ?? 0
        let uam = predictions.uam?.count ?? 0
        let max = [iob, zt, cob, uam].max() ?? 0

        let lastDeltaTime = last.dateString.timeIntervalSince(deliveredAt)
        let additionalTime = CGFloat(TimeInterval(max) * 5.minutes.timeInterval - lastDeltaTime)
        let oneSecondWidth = oneSecondStep(viewWidth: viewWidth)

        return Swift.max(additionalTime * oneSecondWidth, Config.minAdditionalWidth)
    }

    private func oneSecondStep(viewWidth: CGFloat) -> CGFloat {
        viewWidth / (CGFloat(Config.screenHours) * CGFloat(1.hours.timeInterval))
    }

    private func maxPredValue() -> Int {
        [
            suggestion?.predictions?.cob ?? [],
            suggestion?.predictions?.iob ?? [],
            suggestion?.predictions?.zt ?? [],
            suggestion?.predictions?.uam ?? []
        ]
        .flatMap { $0 }
        .max() ?? Config.maxGlucose
    }

    private func minPredValue() -> Int {
        let min =
            [
                suggestion?.predictions?.cob ?? [],
                suggestion?.predictions?.iob ?? [],
                suggestion?.predictions?.zt ?? [],
                suggestion?.predictions?.uam ?? []
            ]
            .flatMap { $0 }
            .min() ?? Config.minGlucose

        return Swift.min(min, Config.minGlucose)
    }

    private func glucoseToCoordinate(_ glucoseEntry: BloodGlucose, fullSize: CGSize) -> CGPoint {
        let x = timeToXCoordinate(glucoseEntry.dateString.timeIntervalSince1970, fullSize: fullSize)
        let y = glucoseToYCoordinate(glucoseEntry.glucose ?? 0, fullSize: fullSize)

        return CGPoint(x: x, y: y)
    }

    private func predictionToCoordinate(_ pred: Int, fullSize: CGSize, index: Int) -> CGPoint {
        guard let deliveredAt = suggestion?.deliverAt else {
            return .zero
        }

        let predTime = deliveredAt.timeIntervalSince1970 + TimeInterval(index) * 5.minutes.timeInterval
        let x = timeToXCoordinate(predTime, fullSize: fullSize)
        let y = glucoseToYCoordinate(pred, fullSize: fullSize)

        return CGPoint(x: x, y: y)
    }

    private func timeToXCoordinate(_ time: TimeInterval, fullSize: CGSize) -> CGFloat {
        let xOffset = -(
            glucose.first?.dateString.timeIntervalSince1970 ?? Date()
                .addingTimeInterval(-1.days.timeInterval).timeIntervalSince1970
        )
        let stepXFraction = fullGlucoseWidth(viewWidth: fullSize.width) / CGFloat(hours.hours.timeInterval)
        let x = CGFloat(time + xOffset) * stepXFraction
        return x
    }

    private func glucoseToYCoordinate(_ glucoseValue: Int, fullSize: CGSize) -> CGFloat {
        let topYPaddint = Config.topYPadding + Config.basalHeight
        let bottomYPadding = Config.bottomYPadding
        let maxValue = max(glucose.compactMap(\.glucose).max() ?? Config.maxGlucose, maxPredValue())
        let minValue = min(glucose.compactMap(\.glucose).min() ?? 0, minPredValue())
        let stepYFraction = (fullSize.height - topYPaddint - bottomYPadding) / CGFloat(maxValue - minValue)
        let yOffset = CGFloat(minValue) * stepYFraction
        let y = fullSize.height - CGFloat(glucoseValue) * stepYFraction + yOffset - bottomYPadding
        return y
    }

    private func timeToInterpolatedPoint(_ time: TimeInterval, fullSize: CGSize) -> CGPoint {
        var nextIndex = 0
        for (index, value) in glucose.enumerated() {
            if value.dateString.timeIntervalSince1970 > time {
                nextIndex = index
                break
            }
        }
        let x = timeToXCoordinate(time, fullSize: fullSize)

        guard nextIndex > 0 else {
            let lastY = glucoseToYCoordinate(glucose.last?.glucose ?? 0, fullSize: fullSize)
            return CGPoint(x: x, y: lastY)
        }

        let prevX = timeToXCoordinate(glucose[nextIndex - 1].dateString.timeIntervalSince1970, fullSize: fullSize)
        let prevY = glucoseToYCoordinate(glucose[nextIndex - 1].glucose ?? 0, fullSize: fullSize)
        let nextX = timeToXCoordinate(glucose[nextIndex].dateString.timeIntervalSince1970, fullSize: fullSize)
        let nextY = glucoseToYCoordinate(glucose[nextIndex].glucose ?? 0, fullSize: fullSize)
        let delta = nextX - prevX
        let fraction = (x - prevX) / delta

        return pointInLine(CGPoint(x: prevX, y: prevY), CGPoint(x: nextX, y: nextY), fraction)
    }

    private func glucoseYRange(fullSize: CGSize) -> (minValue: Int, minY: CGFloat, maxValue: Int, maxY: CGFloat) {
        let topYPaddint = Config.topYPadding + Config.basalHeight
        let bottomYPadding = Config.bottomYPadding
        let maxValue = max(glucose.compactMap(\.glucose).max() ?? Config.maxGlucose, maxPredValue())
        let minValue = min(glucose.compactMap(\.glucose).min() ?? 0, minPredValue())
        let stepYFraction = (fullSize.height - topYPaddint - bottomYPadding) / CGFloat(maxValue - minValue)
        let yOffset = CGFloat(minValue) * stepYFraction
        let maxY = fullSize.height - CGFloat(minValue) * stepYFraction + yOffset - bottomYPadding
        let minY = fullSize.height - CGFloat(maxValue) * stepYFraction + yOffset - bottomYPadding
        return (minValue: minValue, minY: minY, maxValue: maxValue, maxY: maxY)
    }

    private func firstHourDate() -> Date {
        let firstDate = glucose.first?.dateString ?? Date()
        return firstDate.dateTruncated(from: .minute)!
    }

    private func firstHourPosition(viewWidth: CGFloat) -> CGFloat {
        let firstDate = glucose.first?.dateString ?? Date()
        let firstHour = firstHourDate()

        let lastDeltaTime = firstHour.timeIntervalSince(firstDate)
        let oneSecondWidth = oneSecondStep(viewWidth: viewWidth)
        return oneSecondWidth * CGFloat(lastDeltaTime)
    }

    private func calculateTempTargetsRects(fullSize: CGSize) {
        var rects = tempTargets.map { tempTarget -> CGRect in
            let x0 = timeToXCoordinate(tempTarget.createdAt.timeIntervalSince1970, fullSize: fullSize)
            let y0 = glucoseToYCoordinate(Int(tempTarget.targetTop), fullSize: fullSize)
            let x1 = timeToXCoordinate(
                tempTarget.createdAt.timeIntervalSince1970 + Int(tempTarget.duration).minutes.timeInterval,
                fullSize: fullSize
            )
            let y1 = glucoseToYCoordinate(Int(tempTarget.targetBottom), fullSize: fullSize)
            return CGRect(
                x: x0,
                y: y0 - 3,
                width: x1 - x0,
                height: y1 - y0 + 6
            )
        }
        if rects.count > 1 {
            rects = rects.reduce([]) { result, rect -> [CGRect] in
                guard var last = result.last else { return [rect] }
                if last.origin.x + last.width > rect.origin.x {
                    last.size.width = rect.origin.x - last.origin.x
                }
                var res = Array(result.dropLast())
                res.append(contentsOf: [last, rect])
                return res
            }
        }

        tempTargetsPath = Path { path in
            path.addRects(rects)
        }
    }
}
