import Foundation

enum ZoomMode: Equatable, Sendable {
  case fit
  case manual(Double)
}

enum ZoomPolicy {
  static let minimum = 20.0
  static let maximum = 200.0
  static let increment = 5.0

  static func normalized(_ value: Double) -> Double {
    let rounded = (value / increment).rounded(.toNearestOrAwayFromZero) * increment
    return min(maximum, max(minimum, rounded))
  }

  static func stepped(from value: Double, by increments: Int) -> Double {
    guard increments != 0 else { return normalized(value) }
    return normalized(normalized(value) + Double(increments) * increment)
  }
}

enum ZoomSliderMetrics {
  static let sliderWidth = 170.0
  static let containerWidth = 194.0
  static let thumbDiameter = 20.0

  static var horizontalPadding: Double {
    (containerWidth - sliderWidth) / 2
  }

  static func thumbCenter(for value: Double) -> Double {
    let clampedValue = min(ZoomPolicy.maximum, max(ZoomPolicy.minimum, value))
    let fraction =
      (clampedValue - ZoomPolicy.minimum)
      / (ZoomPolicy.maximum - ZoomPolicy.minimum)
    return thumbDiameter / 2 + fraction * (sliderWidth - thumbDiameter)
  }

  static func labelCenter(for value: Double) -> Double {
    horizontalPadding + thumbCenter(for: value)
  }
}
