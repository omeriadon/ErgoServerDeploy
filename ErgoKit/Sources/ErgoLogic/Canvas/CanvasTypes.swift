//
//  CanvasTypes.swift
//  ErgoKit
//
//  Created by Adon Omeri on 6/11/2026.
//

import Foundation

/// A point on the canvas. ErgoLogic can't use CGPoint because the server builds it on Linux, so the app converts at the edge.
public struct CanvasPoint: Hashable, Codable, Sendable {
	public var x: Double
	public var y: Double

	public static let zero = CanvasPoint(x: 0, y: 0)

	public init(x: Double, y: Double) {
		self.x = x
		self.y = y
	}

	public func distance(to other: CanvasPoint) -> Double {
		hypot(other.x - x, other.y - y)
	}

	public static func + (left: CanvasPoint, right: CanvasPoint) -> CanvasPoint {
		CanvasPoint(x: left.x + right.x, y: left.y + right.y)
	}

	public static func - (left: CanvasPoint, right: CanvasPoint) -> CanvasPoint {
		CanvasPoint(x: left.x - right.x, y: left.y - right.y)
	}

	public static func * (point: CanvasPoint, scale: Double) -> CanvasPoint {
		CanvasPoint(x: point.x * scale, y: point.y * scale)
	}
}

public struct CanvasSize: Hashable, Codable, Sendable {
	public var width: Double
	public var height: Double

	public init(width: Double, height: Double) {
		self.width = width
		self.height = height
	}
}

/// A box on the canvas. A statement's `position` is its centre, so arrows can run centre to centre.
public struct CanvasRect: Hashable, Codable, Sendable {
	public var center: CanvasPoint
	public var size: CanvasSize

	public var minX: Double {
		center.x - size.width / 2
	}

	public var maxX: Double {
		center.x + size.width / 2
	}

	public var minY: Double {
		center.y - size.height / 2
	}

	public var maxY: Double {
		center.y + size.height / 2
	}

	public init(center: CanvasPoint, size: CanvasSize) {
		self.center = center
		self.size = size
	}

	public func contains(_ point: CanvasPoint) -> Bool {
		point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
	}

	/// Boxes that only touch don't intersect. `margin` is extra room each box must keep from the other.
	public func intersects(_ other: CanvasRect, margin: Double = 0) -> Bool {
		abs(center.x - other.center.x) < (size.width + other.size.width) / 2 + margin
			&& abs(center.y - other.center.y) < (size.height + other.size.height) / 2 + margin
	}
}
