import Foundation

/// Immediate Auto+ increases; sustained cooling followed by bounded decreases.
/// Time is monotonic and supplied by the controller, not sensor wall-clock time.
struct FanResponseSmoother: Sendable {
    private var output: Double?
    private var lastSampleTime: TimeInterval?
    private var coolingSince: TimeInterval?
    private var lastDecreaseTime: TimeInterval?
    private var demandLowWater = 100.0

    mutating func target(for demand: Double, at now: TimeInterval) -> Double {
        let demand = demand.isFinite ? min(100, max(0, demand)) : 100
        guard now.isFinite else { return max(output ?? demand, demand) }
        guard let previous = output else {
            output = demand
            lastSampleTime = now
            demandLowWater = demand
            return demand
        }
        // Sleep, missing telemetry, and clock resets do not count as cooling.
        if let lastSampleTime, now < lastSampleTime || now - lastSampleTime > 10 {
            coolingSince = nil
            lastDecreaseTime = nil
            demandLowWater = demand
        }
        lastSampleTime = now
        if demand >= previous {
            output = demand
            coolingSince = nil
            lastDecreaseTime = nil
            demandLowWater = demand
            return demand
        }
        // Ignore sub-one-point downward jitter; never suppress an increase.
        guard previous - demand >= 1 else {
            coolingSince = nil
            lastDecreaseTime = nil
            demandLowWater = demand
            return previous
        }
        // A rebound below the held output still indicates renewed heating.
        // A low-water mark catches small cumulative rises as well.
        if coolingSince == nil || demand >= demandLowWater + 1 {
            coolingSince = now
            lastDecreaseTime = now + 20
            demandLowWater = demand
            return previous
        }
        demandLowWater = min(demandLowWater, demand)
        guard let coolingSince, now >= coolingSince + 20,
              let lastDecreaseTime, now - lastDecreaseTime >= 5 else { return previous }
        // One percentage point per second, capped at five points per update.
        // Delayed calls never accumulate a large catch-up drop.
        let next = max(demand, previous - min(5, now - lastDecreaseTime))
        output = next
        self.lastDecreaseTime = now
        return next
    }
}
