import EditXPlugin
import GaeaProtocol
import MLXStepAudioEditX
import MLXToolKit
import Testing

@Suite struct PlanTests {
    @Test func emotionsAndStylesMapToUpstream() throws {
        #expect(try editPlan(edit: ["kind": "emotion", "emotion": "afraid"], transcript: "Hello there.", seed: 1).edit == .emotion("fear"))
        #expect(try editPlan(edit: ["kind": "emotion", "emotion": "neutral"], transcript: "Hello there.", seed: 1).edit == .emotion("remove"))
        #expect(try editPlan(edit: ["kind": "style", "style": "narration"], transcript: "Hello there.", seed: 1).edit == .style("story"))
        #expect(try editPlan(edit: ["kind": "style", "style": "normal"], transcript: "Hello there.", seed: 1).edit == .style("remove"))
        #expect(try editPlan(edit: ["kind": "trim_silence"], transcript: "Hello there.", seed: 1).edit == .trimSilence)
        // Every label upstream lists, and nothing else.
        #expect(Set(emotionLabels.map(\.upstream)).isSubset(of: StepAudioEditXPackage.emotionLabels))
        #expect(Set(styleLabels.map(\.upstream)).isSubset(of: StepAudioEditXPackage.styleLabels))
        #expect(Set(cueTags.map(\.upstream)).isSubset(of: StepAudioEditXPackage.paralinguisticTags))
    }

    @Test func addCuePlacesTheTagAndReturnsTheNewTranscript() throws {
        let end = try editPlan(edit: ["kind": "add_cue", "cue": "laugh"], transcript: "That was close.", seed: 1)
        #expect(end.edit == .paralinguistic(targetTranscript: "That was close.[Laughter]"))
        #expect(end.newTranscript == "That was close. [laugh]")
        let start = try editPlan(edit: ["kind": "add_cue", "cue": "sigh", "at": "start"], transcript: "Fine.", seed: 1)
        #expect(start.edit == .paralinguistic(targetTranscript: "[Sigh]Fine."))
        #expect(start.newTranscript == "[sigh] Fine.")
        let inline = try editPlan(edit: ["kind": "add_cue", "cue": "breath", "text": "Okay [breath] let's go."], transcript: "Okay let's go.", seed: 1)
        #expect(inline.edit == .paralinguistic(targetTranscript: "Okay [Breathing] let's go."))
        #expect(inline.newTranscript == "Okay [breath] let's go.")
        #expect(throws: GPPError.self) { try editPlan(edit: ["kind": "add_cue", "cue": "laugh", "text": "No cue here."], transcript: "No cue here.", seed: 1) }
        #expect(throws: GPPError.self) { try editPlan(edit: ["kind": "add_cue", "cue": "laugh", "at": "middle"], transcript: "Hi.", seed: 1) }
        #expect(throws: GPPError.self) { try editPlan(edit: ["kind": "add_cue", "cue": "cough"], transcript: "Hi.", seed: 1) }
    }

    @Test func transcriptsReadCuesAndDropTheOthers() throws {
        #expect(segments(#"A \[note] [laugh] [S1] [pause 1.5s] end"#)
            == [.text("A [note] "), .cue("laugh"), .text(" [S1] "), .cue("pause"), .text(" end")])
        let (text, warnings) = modelText("Well [cough] I [laugh] guess [cough] so.", param: "transcript")
        #expect(text == "Well I [Laughter] guess so.")
        #expect(warnings.map(\.code) == ["cue_unsupported"])
        let plan = try editPlan(edit: ["kind": "denoise"], transcript: "Well [laugh] okay.", seed: 1)
        #expect(plan.transcript == "Well [Laughter] okay.")
        #expect(plan.newTranscript == nil)
    }

    @Test func refusals() {
        #expect(throws: GPPError.self) { try editPlan(edit: ["kind": "emotion", "emotion": "calm"], transcript: "Hi.", seed: 1) }
        #expect(throws: GPPError.self) { try editPlan(edit: ["kind": "speed", "factor": 1.5], transcript: "Hi.", seed: 1) }
        #expect(throws: GPPError.self) { try editPlan(edit: ["kind": "denoise"], transcript: "  ", seed: 1) }
        #expect(throws: GPPError.self) { try editPlan(edit: ["kind": "denoise"], transcript: "[cough]", seed: 1) }
        #expect(throws: GPPError.self) { try editPlan(edit: ["kind": "denoise"], transcript: String(repeating: "a", count: 1501), seed: 1) }
    }

    @Test func effectiveCarriesTheSeedAndUpstreamsEdit() throws {
        let plan = try editPlan(edit: ["kind": "emotion", "emotion": "humorous"], transcript: "Hi.", seed: 7)
        #expect(plan.effective["seed"] == .int(7))
        #expect(plan.effective["x-stepfun.edit"] == .string("emotion:humour"))
    }
}
