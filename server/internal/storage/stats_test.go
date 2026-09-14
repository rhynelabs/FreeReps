package storage

import "testing"

// TestPlanRowsReadsTopNodeEstimate exists because the metric row count now
// comes from EXPLAIN output rather than COUNT(*): the estimate must be read
// from the top node (the chunk Append on a hypertable), whose "Plan Rows" is
// the sum over the chunks below it, and not from any child.
func TestPlanRowsReadsTopNodeEstimate(t *testing.T) {
	explain := []byte(`[
	  {
	    "Plan": {
	      "Node Type": "Append",
	      "Plan Rows": 2345678,
	      "Plans": [
	        {"Node Type": "Index Only Scan", "Plan Rows": 1000000},
	        {"Node Type": "Index Only Scan", "Plan Rows": 1345678}
	      ]
	    }
	  }
	]`)
	got, err := planRows(explain)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != 2345678 {
		t.Errorf("rows = %d, want 2345678", got)
	}
}

// TestPlanRowsRejectsEmptyOutput exists so a malformed or empty EXPLAIN result
// surfaces as an error rather than as a silent count of zero.
func TestPlanRowsRejectsEmptyOutput(t *testing.T) {
	if _, err := planRows([]byte(`[]`)); err == nil {
		t.Error("expected an error for an output without a plan")
	}
	if _, err := planRows([]byte(`not json`)); err == nil {
		t.Error("expected an error for non-JSON output")
	}
}
