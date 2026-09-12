/// Retains both extrema in each bucket, plus endpoints. Unlike uniform stride
/// sampling, a short temperature or fan spike stays visible in a six-hour plot.
public enum PlotSampling {
    public static func extremaIndices<C: RandomAccessCollection>(
        in samples: C, maximumPoints: Int, value: (C.Element) -> Double?
    ) -> [C.Index] {
        guard samples.count > maximumPoints, maximumPoints >= 4 else { return Array(samples.indices) }
        let buckets = (maximumPoints - 2) / 2
        let interiorCount = samples.count - 2
        var result: [C.Index] = []
        result.reserveCapacity(maximumPoints)
        result.append(samples.startIndex)
        for bucket in 0..<buckets {
            let start = samples.index(samples.startIndex, offsetBy: 1 + bucket * interiorCount / buckets)
            let end = samples.index(samples.startIndex, offsetBy: 1 + (bucket + 1) * interiorCount / buckets)
            var low = start
            var high = start
            var lowValue = Double.infinity
            var highValue = -Double.infinity
            for index in samples[start..<end].indices {
                guard let number = value(samples[index]), number.isFinite else { continue }
                if number < lowValue { low = index; lowValue = number }
                if number > highValue { high = index; highValue = number }
            }
            result.append(min(low, high))
            if low != high { result.append(max(low, high)) }
        }
        result.append(samples.index(before: samples.endIndex))
        return result
    }
}
