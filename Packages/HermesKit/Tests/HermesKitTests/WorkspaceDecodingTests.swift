import Foundation
import Testing

@testable import HermesKit

/// Decoding of the cron, kanban and file payloads, from shapes recorded off a 0.23 backend.
@Suite struct WorkspaceDecodingTests {
  @Test func cronJobsReadTheirScheduleAndState() throws {
    let json = try JSONValue.parse(#"""
      {"id": "a1b2c3d4e5f6", "name": "Nightly digest", "prompt": "Check the shop.", "profile": "default",
       "schedule": {"kind": "cron", "expr": "* * * * *", "display": "* * * * *"}, "schedule_display": "* * * * *",
       "repeat": {"times": null, "completed": 58084}, "enabled": true, "state": "scheduled",
       "next_run_at": "2026-11-11T22:22:00-05:00", "last_run_at": "2026-11-11T22:21:45.051515-05:00",
       "last_status": "ok", "failure_streak": 0, "no_agent": true, "script": "watch.py", "deliver": "slack",
       "live_execution": null}
      """#)
    let job = CronJob(json: json)
    #expect(job.title == "Nightly digest")
    #expect(job.schedule == "* * * * *")
    #expect(job.completedRuns == 58084)
    #expect(job.repeatTimes == nil)
    #expect(!job.isPaused)
    #expect(!job.isRunning)
    #expect(!job.lastRunFailed)
    #expect(job.isScript)
    #expect(job.nextRunAt == Date(timeIntervalSince1970: 1_794_453_720))
    #expect(job.lastRunAt == Date(timeIntervalSince1970: 1_794_453_705))

    let paused = CronJob(json: ["id": "x", "prompt": "A long prompt that names the job", "enabled": false, "state": "paused"])
    #expect(paused.isPaused)
    #expect(paused.title == "A long prompt that names the job")
  }

  @Test func cronRunsTellChatsFromScriptOutput() {
    let script = CronRun(json: ["id": "cron_output:e69:2026-11-11_22-26-45", "title": "COMPLETED · # Cron Job", "source": "cron_output"])
    #expect(!script.isChat)
    #expect(script.outcome == "Completed")
    let chat = CronRun(json: ["id": "20261111_090000_abc123", "title": "Morning digest", "source": "cron"])
    #expect(chat.isChat)
    #expect(chat.outcome == "")
  }

  @Test func kanbanBoardsAndTasksDecode() throws {
    let board = KanbanBoard(json: try JSONValue.parse(#"""
      {"columns": [{"name": "todo", "tasks": []},
                   {"name": "blocked", "tasks": [{"id": "t_1", "title": "Fix it", "status": "blocked", "assignee": "builder",
                    "block_kind": "needs_input", "comment_count": 11, "progress": {"done": 1, "total": 3},
                    "warnings": {"count": 2}, "created_at": 100, "started_at": 200}]}],
       "assignees": ["scout", "builder"], "latest_event_id": 42, "tenants": []}
      """#))
    #expect(board.columns.map(\.label) == ["To do", "Blocked"])
    #expect(board.latestEventID == 42)
    let task = try #require(board.columns.last?.tasks.first)
    #expect(task.blockKind == "needs_input")
    #expect(task.progressDone == 1)
    #expect(task.progressTotal == 3)
    #expect(task.warningCount == 2)
    #expect(task.recency == 200)

    let detail = KanbanTaskDetail(json: try JSONValue.parse(#"""
      {"task": {"id": "t_1", "title": "Fix it", "status": "done"},
       "comments": [{"id": 3, "author": "builder", "body": "Done.", "created_at": 300}],
       "runs": [{"id": 9, "profile": "builder", "status": "done", "metadata": "{\"session_id\": \"20261111_1\"}"}],
       "links": {"parents": ["t_0"], "children": []}, "link_tasks": [{"id": "t_0", "title": "Parent", "status": "done"}]}
      """#))
    #expect(detail.comments.first?.id == "3")
    #expect(detail.runs.first?.sessionID == "20261111_1")
    #expect(detail.parents.first?.title == "Parent")
  }

  @Test func downloadNamesComeFromTheServer() {
    #expect(HermesHTTP.filename(from: #"attachment; filename="talaria-probe.txt""#) == "talaria-probe.txt")
    #expect(HermesHTTP.filename(from: "attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf") == "résumé.pdf")
    #expect(HermesHTTP.filename(from: nil) == nil)
    #expect(HermesHTTP.safeFilename("a/b:c.txt") == "a-b-c.txt")
  }
}
