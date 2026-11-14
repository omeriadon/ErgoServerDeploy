//
//  LogicCourseTests.swift
//  ErgoKit
//
//  Created by Adon Omeri on 10/11/2026.
//

import ErgoLogic
import Testing

/// A course that teaches a wrong answer is worse than no course
struct LogicCourseTests {
	@Test(arguments: LogicCourse.lessons.flatMap(\.exercises))
	func everyAnswerMatchesTheChecker(_ exercise: LogicExercise) {
		let analysis = LogicChecker.analyze(exercise.entries)
		#expect(analysis.parse.diagnostics.isEmpty, "Doesn't parse: \(exercise.argument)")
		switch analysis.verdict {
			case .valid:
				#expect(exercise.isValid, "Valid, but marked invalid: \(exercise.argument)")
			case .invalid:
				#expect(!exercise.isValid, "Invalid, but marked valid: \(exercise.argument)")
			case .undecided, nil:
				Issue.record("Not settled: \(exercise.argument)")
		}
	}

	@Test func idsAreUnique() {
		let ids = LogicCourse.lessons.map(\.id)
		#expect(Set(ids).count == ids.count)
	}
}
