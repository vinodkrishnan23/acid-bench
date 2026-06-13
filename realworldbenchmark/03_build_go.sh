#!/usr/bin/env bash
# 03_build_go.sh — RWB Go binaries: perop / clientbulk / srvmon with rich ledger inserts.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin

mkdir -p "$GO_DIR/perop" "$GO_DIR/clientbulk" "$GO_DIR/srvmon"
cd "$GO_DIR"
[[ -f go.mod ]] || go mod init rwbbench

read -r -d '' CONSTS <<'EOF' || true
const (
	dbName       = "fss_acid_proof"
	numCards     = 1_000_000
	numMerchants = 5_000
	merchBuckets = 256
	hotFrac      = 0.02
	hotShare     = 0.80
	pLatencyMs   = 20.0
	txnAmountMin = 100
	txnAmountMax = 5000
)

var errInsufficient = fmt.Errorf("insufficient_funds")
var schemes  = []string{"VISA","MASTERCARD","RUPAY","AMEX"}
var statuses = []string{"APPROVED","DECLINED","REVERSED"}
var rules    = []string{"VEL_HOUR_OK","VEL_DAY_OK","KYC_VERIFIED","NEW_DEVICE","NO_CHARGEBACK","INTL_OFF","MCC_ALLOWED","TIMEZONE_NORMAL","IP_TRUSTED","DEVICE_BOUND"}
var cities   = []string{"Mumbai","Delhi","Bangalore","Hyderabad","Chennai","Kolkata","Pune","Ahmedabad","Jaipur","Lucknow"}
var states   = []string{"Maharashtra","Delhi","Karnataka","Telangana","Tamil Nadu","West Bengal","Gujarat","Rajasthan","Uttar Pradesh"}

func cardID(i int) string  { return fmt.Sprintf("CARD-%010d", i) }
func merchID(i int) string { return fmt.Sprintf("M%07d", i) }
func hourBucket(t time.Time) string { return t.UTC().Format("2006010215") }
func dayBucket(t time.Time) string  { return t.UTC().Format("20060102") }

func pickMerchant(r *rand.Rand) int {
	hotN := int(float64(numMerchants) * hotFrac)
	if hotN < 1 { hotN = 1 }
	if r.Float64() < hotShare { return r.Intn(hotN) }
	return hotN + r.Intn(numMerchants-hotN)
}

func envInt(k string, def int) int {
	if v := os.Getenv(k); v != "" { var n int; fmt.Sscan(v, &n); if n > 0 { return n } }
	return def
}

// randStr — fast 16-byte hex string (no crypto needed for bench).
func randStr(r *rand.Rand) string {
	var b [8]byte
	binary.LittleEndian.PutUint64(b[:], r.Uint64())
	return fmt.Sprintf("%x", b)
}

// buildLedgerDoc — lean shape, target ~92 leaf fields (was ~195 with rich trace + verbose subdocs).
func buildLedgerDoc(cardStr, midStr string, amount int64, now time.Time, r *rand.Rand) bson.M {
	city  := cities[r.Intn(len(cities))]
	state := states[r.Intn(len(states))]
	// 5 entries × 5 fields = 25 trace leaves → total ~93
	traceSteps := []string{"AUTH","RISK","VELOCITY","COMMIT","SETTLE"}
	trace := make([]bson.M, len(traceSteps))
	for i, step := range traceSteps {
		trace[i] = bson.M{
			"step":    step,
			"ts":      now.Add(time.Duration(i) * time.Millisecond),
			"latency": r.Intn(20),
			"outcome": "ok",
			"node":    fmt.Sprintf("auth-node-%02d", r.Intn(50)),
		}
	}
	return bson.M{
		// 8 identification
		"type":            "PURCHASE",
		"amount":          amount,
		"currency":        "INR",
		"original_amount": amount,
		"status":          statuses[r.Intn(len(statuses))],
		"cardId":          cardStr,
		"mid":             midStr,
		"ts":              now,
		// 10 card_snapshot
		"card_snapshot": bson.M{
			"masked_pan": "411111******" + fmt.Sprintf("%04d", r.Intn(10000)),
			"scheme":     schemes[r.Intn(len(schemes))],
			"type":       "credit",
			"tier":       "platinum",
			"network":    "VisaNet",
			"bin":        "411111",
			"issuer":     "HDFC Bank",
			"country":    "IN",
			"region":     "South",
			"verified":   true,
		},
		// 9 merchant_snapshot
		"merchant_snapshot": bson.M{
			"brand":      "BrandName",
			"mcc":        5411,
			"mcc_name":   "GROCERY_STORES",
			"terminal":   "T" + randStr(r)[:8],
			"city":       city,
			"state":      state,
			"country":    "IN",
			"risk_tier":  "LOW",
			"settlement": "T+1",
		},
		// 6 auth
		"auth": bson.M{
			"rrn":           randStr(r) + randStr(r),
			"arn":           randStr(r) + randStr(r),
			"stan":          fmt.Sprintf("%06d", r.Intn(1000000)),
			"approval_code": fmt.Sprintf("%06d", r.Intn(1000000)),
			"auth_method":   "chip_contactless",
			"acquirer_id":   "ACQ001",
		},
		// 4 risk
		"risk": bson.M{
			"score":           r.Intn(100),
			"rules_triggered": rules[:3],
			"decision":        "approve",
			"engine_version":  "risk-engine-v4.2",
		},
		// 4 velocity_snapshot
		"velocity_snapshot": bson.M{
			"card_count_24h": r.Intn(50),
			"card_sum_24h":   r.Intn(100000),
			"merch_count_1h": r.Intn(500),
			"merch_sum_1h":   r.Intn(500000),
		},
		// 4 operational
		"operational": bson.M{
			"response_time_ms": r.Intn(50),
			"network_path":     "primary",
			"correlation_id":   randStr(r),
			"trace_id":         randStr(r),
		},
		// 5 settlement
		"settlement": bson.M{
			"batch_id":          randStr(r),
			"settled_at":        now.Add(24 * time.Hour),
			"settlement_amount": amount,
			"interchange_fee":   int64(float64(amount) * 0.011),
			"net":               int64(float64(amount) * 0.984),
		},
		// 4 three_ds
		"three_ds": bson.M{
			"enrolled":      true,
			"authenticated": true,
			"eci":           "05",
			"cavv":          randStr(r) + randStr(r),
		},
		// 4 device
		"device": bson.M{
			"device_id": randStr(r) + randStr(r),
			"ua":        "Mozilla/5.0 (compatible) RWBClient/1.0",
			"ip_hash":   randStr(r) + randStr(r),
			"os":        "iOS 18.2",
		},
		// 6 geo
		"geo": bson.M{
			"city":    city,
			"state":   state,
			"country": "IN",
			"lat":     12.97 + r.Float64(),
			"lng":     77.59 + r.Float64(),
			"ip":      fmt.Sprintf("%d.%d.%d.%d", r.Intn(254)+1, r.Intn(254), r.Intn(254), r.Intn(254)),
		},
		// 3 audit
		"audit": bson.M{
			"createdAt":   now,
			"processedBy": "auth-cluster-01",
			"version":     1,
		},
		// 1 notes
		"notes": "Authorization completed within SLA.",
		// 25 trace leaves (5 × 5)
		"trace": trace,
	}
}
EOF

# ============================ PER-OP VARIANT ============================
cat > perop/main.go <<EOF
package main

import (
	"context"
	"encoding/binary"
	"fmt"
	"math/rand"
	"os"
	"sort"
	"sync"
	"time"

	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
	"go.mongodb.org/mongo-driver/v2/mongo/writeconcern"
)

$CONSTS

func main() {
	if len(os.Args) < 4 { fmt.Println("usage: perop <sessions> <target_tps> <duration_s>"); os.Exit(1) }
	var sessions, targetTPS, durSec int
	fmt.Sscan(os.Args[1], &sessions); fmt.Sscan(os.Args[2], &targetTPS); fmt.Sscan(os.Args[3], &durSec)
	minPool := envInt("MIN_POOL", 500); maxPool := envInt("MAX_POOL", 1000)
	warmupSec := envInt("WARMUP_SEC", 10)
	cycle := time.Duration(float64(sessions)/float64(targetTPS)*1000) * time.Millisecond

	uri := os.Getenv("MONGO_URI"); ctx := context.Background()
	cli, err := mongo.Connect(options.Client().ApplyURI(uri).
		SetMaxPoolSize(uint64(maxPool)).SetMinPoolSize(uint64(minPool)))
	if err != nil { panic(err) }
	defer cli.Disconnect(ctx)
	if err := cli.Ping(ctx, nil); err != nil { panic(err) }
	{ var w sync.WaitGroup
		for i := 0; i < 200; i++ { w.Add(1); go func(){ defer w.Done(); for k:=0;k<20;k++{cli.Ping(ctx,nil)} }() }
		w.Wait(); time.Sleep(2*time.Second) }

	db := cli.Database(dbName)
	cards := db.Collection("cards"); ledger := db.Collection("txn_ledger")
	cardVel := db.Collection("cardholder_velocity"); merchVel := db.Collection("merchant_velocity")
	txnOpts := options.Transaction().SetWriteConcern(writeconcern.Majority())
	upsertOpt := options.UpdateOne().SetUpsert(true)

	var wg sync.WaitGroup
	latCh := make([][]float64, sessions); committed := make([]int, sessions)
	errs := make([]int, sessions); retries := make([]int, sessions)
	start := time.Now(); deadline := start.Add(time.Duration(durSec)*time.Second)

	for i := 0; i < sessions; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			r := rand.New(rand.NewSource(time.Now().UnixNano()+int64(id)))
			time.Sleep(time.Duration(int64(cycle)/int64(sessions)*int64(id)))
			sess, err := cli.StartSession(); if err != nil { errs[id]++; return }
			defer sess.EndSession(ctx)
			local := make([]float64, 0, 4096)
			for time.Now().Before(deadline) {
				cIdx := r.Intn(numCards) + 1
				mIdx := pickMerchant(r) + 1
				amount := int64(r.Intn(txnAmountMax-txnAmountMin+1) + txnAmountMin)
				cb := r.Intn(merchBuckets)
				cidStr := cardID(cIdx); midStr := merchID(mIdx)
				now := time.Now(); hb := hourBucket(now); dbStr := dayBucket(now)
				cvID := bson.D{{Key: "cardId", Value: cidStr}, {Key: "bucket", Value: dbStr}}
				mvID := bson.D{{Key: "mid", Value: midStr}, {Key: "bucket", Value: hb}, {Key: "cb", Value: cb}}
				attempts := 0
				t0 := time.Now()
				txnCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
				_, txErr := sess.WithTransaction(txnCtx, func(sc context.Context) (interface{}, error) {
					attempts++
					res, e := cards.UpdateOne(sc,
						bson.M{"_id": cidStr, "status": "ACTIVE", "balance": bson.M{"\$gte": amount}},
						bson.M{"\$inc": bson.M{"balance": -amount, "version": 1}, "\$set": bson.M{"last_updated": now, "activity.last_txn_at": now}})
					if e != nil { return nil, e }
					if res.MatchedCount == 0 { return nil, errInsufficient }
					if _, e = ledger.InsertOne(sc, buildLedgerDoc(cidStr, midStr, amount, now, r)); e != nil { return nil, e }
					if _, e = cardVel.UpdateOne(sc, bson.M{"_id": cvID},
						bson.M{"\$inc": bson.M{"count": 1, "sum": amount}, "\$set": bson.M{"updatedAt": now}},
						upsertOpt); e != nil { return nil, e }
					if _, e = merchVel.UpdateOne(sc, bson.M{"_id": mvID},
						bson.M{"\$inc": bson.M{"count": 1, "sum": amount}, "\$set": bson.M{"updatedAt": now}},
						upsertOpt); e != nil { return nil, e }
					return nil, nil
				}, txnOpts)
				cancel()
				if attempts > 1 { retries[id] += attempts - 1 }
				wall := float64(time.Since(t0).Microseconds())/1000.0
				if txErr == errInsufficient { } else if txErr != nil { errs[id]++ } else {
					if time.Since(start).Seconds() > float64(warmupSec) { local = append(local, wall); committed[id]++ }
				}
				if rem := cycle - time.Since(t0); rem > 0 { time.Sleep(time.Duration(float64(rem)*(0.8+0.4*r.Float64()))) }
			}
			latCh[id] = local
		}(i)
	}
	wg.Wait()
	report("PER-OP", latCh, committed, errs, retries, time.Since(start).Seconds(), float64(warmupSec))
}

func report(name string, latCh [][]float64, committed, errs, retries []int, elapsed, warmup float64) {
	var all []float64; tc, te, tr := 0, 0, 0
	for i := range latCh { all = append(all, latCh[i]...); tc += committed[i]; te += errs[i]; tr += retries[i] }
	sort.Float64s(all)
	win := elapsed - warmup; if win <= 0 { win = elapsed }
	pct := func(p float64) float64 { if len(all)==0 {return 0}; idx:=int(p/100*float64(len(all))); if idx>=len(all){idx=len(all)-1}; return all[idx] }
	fmt.Println("==================================================")
	fmt.Printf("GO RWB-%s STEADY-STATE (%.1fs total, %.1fs measured)\n", name, elapsed, win)
	fmt.Println("==================================================")
	fmt.Printf("  committed (post-warmup): %d  windowed TPS: %.0f  errors: %d\n", tc, float64(tc)/win, te)
	if tc > 0 { fmt.Printf("  retries: %d  (%.2f%% of committed)\n", tr, 100.0*float64(tr)/float64(tc)) }
	if len(all) > 0 {
		fmt.Printf("  median %.2f  p95 %.2f  p99 %.2f  p99.9 %.2f  max %.2f\n",
			pct(50), pct(95), pct(99), pct(99.9), all[len(all)-1])
		pass := pct(99) <= pLatencyMs && float64(tc)/win >= float64(0.95)*5000
		fmt.Printf("  PASS (p99<=20ms)? %v\n", pass)
	}
}
EOF

# ============================ CLIENT-BULK VARIANT ============================
cat > clientbulk/main.go <<EOF
package main

import (
	"context"
	"encoding/binary"
	"fmt"
	"math/rand"
	"os"
	"sort"
	"sync"
	"time"

	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
	"go.mongodb.org/mongo-driver/v2/mongo/writeconcern"
)

$CONSTS

func main() {
	if len(os.Args) < 4 { fmt.Println("usage: clientbulk <sessions> <target_tps> <duration_s>"); os.Exit(1) }
	var sessions, targetTPS, durSec int
	fmt.Sscan(os.Args[1], &sessions); fmt.Sscan(os.Args[2], &targetTPS); fmt.Sscan(os.Args[3], &durSec)
	minPool := envInt("MIN_POOL", 500); maxPool := envInt("MAX_POOL", 1000)
	warmupSec := envInt("WARMUP_SEC", 10)
	cycle := time.Duration(float64(sessions)/float64(targetTPS)*1000) * time.Millisecond

	uri := os.Getenv("MONGO_URI"); ctx := context.Background()
	cli, err := mongo.Connect(options.Client().ApplyURI(uri).
		SetMaxPoolSize(uint64(maxPool)).SetMinPoolSize(uint64(minPool)))
	if err != nil { panic(err) }
	defer cli.Disconnect(ctx)
	if err := cli.Ping(ctx, nil); err != nil { panic(err) }
	{ var w sync.WaitGroup
		for i := 0; i < 200; i++ { w.Add(1); go func(){ defer w.Done(); for k:=0;k<20;k++{cli.Ping(ctx,nil)} }() }
		w.Wait(); time.Sleep(2*time.Second) }

	txnOpts := options.Transaction().SetWriteConcern(writeconcern.Majority())

	var wg sync.WaitGroup
	latCh := make([][]float64, sessions); committed := make([]int, sessions)
	errs := make([]int, sessions); retries := make([]int, sessions)
	start := time.Now(); deadline := start.Add(time.Duration(durSec)*time.Second)

	for i := 0; i < sessions; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			r := rand.New(rand.NewSource(time.Now().UnixNano()+int64(id)))
			time.Sleep(time.Duration(int64(cycle)/int64(sessions)*int64(id)))
			sess, err := cli.StartSession(); if err != nil { errs[id]++; return }
			defer sess.EndSession(ctx)
			local := make([]float64, 0, 4096)
			for time.Now().Before(deadline) {
				cIdx := r.Intn(numCards) + 1
				mIdx := pickMerchant(r) + 1
				amount := int64(r.Intn(txnAmountMax-txnAmountMin+1) + txnAmountMin)
				cb := r.Intn(merchBuckets)
				cidStr := cardID(cIdx); midStr := merchID(mIdx)
				now := time.Now(); hb := hourBucket(now); dbStr := dayBucket(now)
				cvID := bson.D{{Key: "cardId", Value: cidStr}, {Key: "bucket", Value: dbStr}}
				mvID := bson.D{{Key: "mid", Value: midStr}, {Key: "bucket", Value: hb}, {Key: "cb", Value: cb}}
				attempts := 0
				t0 := time.Now()
				txnCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
				_, txErr := sess.WithTransaction(txnCtx, func(sc context.Context) (interface{}, error) {
					attempts++
					writes := []mongo.ClientBulkWrite{
						{Database: dbName, Collection: "cards",
							Model: mongo.NewClientUpdateOneModel().
								SetFilter(bson.M{"_id": cidStr, "status": "ACTIVE", "balance": bson.M{"\$gte": amount}}).
								SetUpdate(bson.M{"\$inc": bson.M{"balance": -amount, "version": 1}, "\$set": bson.M{"last_updated": now, "activity.last_txn_at": now}})},
						{Database: dbName, Collection: "txn_ledger",
							Model: mongo.NewClientInsertOneModel().
								SetDocument(buildLedgerDoc(cidStr, midStr, amount, now, r))},
						{Database: dbName, Collection: "cardholder_velocity",
							Model: mongo.NewClientUpdateOneModel().
								SetFilter(bson.M{"_id": cvID}).
								SetUpdate(bson.M{"\$inc": bson.M{"count": 1, "sum": amount}, "\$set": bson.M{"updatedAt": now}}).
								SetUpsert(true)},
						{Database: dbName, Collection: "merchant_velocity",
							Model: mongo.NewClientUpdateOneModel().
								SetFilter(bson.M{"_id": mvID}).
								SetUpdate(bson.M{"\$inc": bson.M{"count": 1, "sum": amount}, "\$set": bson.M{"updatedAt": now}}).
								SetUpsert(true)},
					}
					res, e := cli.BulkWrite(sc, writes, options.ClientBulkWrite().SetOrdered(true))
					if e != nil { return nil, e }
					if res.MatchedCount + res.UpsertedCount < 3 { return nil, errInsufficient }
					return nil, nil
				}, txnOpts)
				cancel()
				if attempts > 1 { retries[id] += attempts - 1 }
				wall := float64(time.Since(t0).Microseconds())/1000.0
				if txErr == errInsufficient { } else if txErr != nil { errs[id]++ } else {
					if time.Since(start).Seconds() > float64(warmupSec) { local = append(local, wall); committed[id]++ }
				}
				if rem := cycle - time.Since(t0); rem > 0 { time.Sleep(time.Duration(float64(rem)*(0.8+0.4*r.Float64()))) }
			}
			latCh[id] = local
		}(i)
	}
	wg.Wait()
	report("CLIENT-BULK", latCh, committed, errs, retries, time.Since(start).Seconds(), float64(warmupSec))
}

func report(name string, latCh [][]float64, committed, errs, retries []int, elapsed, warmup float64) {
	var all []float64; tc, te, tr := 0, 0, 0
	for i := range latCh { all = append(all, latCh[i]...); tc += committed[i]; te += errs[i]; tr += retries[i] }
	sort.Float64s(all)
	win := elapsed - warmup; if win <= 0 { win = elapsed }
	pct := func(p float64) float64 { if len(all)==0 {return 0}; idx:=int(p/100*float64(len(all))); if idx>=len(all){idx=len(all)-1}; return all[idx] }
	fmt.Println("==================================================")
	fmt.Printf("GO RWB-%s STEADY-STATE (%.1fs total, %.1fs measured)\n", name, elapsed, win)
	fmt.Println("==================================================")
	fmt.Printf("  committed (post-warmup): %d  windowed TPS: %.0f  errors: %d\n", tc, float64(tc)/win, te)
	if tc > 0 { fmt.Printf("  retries: %d  (%.2f%% of committed)\n", tr, 100.0*float64(tr)/float64(tc)) }
	if len(all) > 0 {
		fmt.Printf("  median %.2f  p95 %.2f  p99 %.2f  p99.9 %.2f  max %.2f\n",
			pct(50), pct(95), pct(99), pct(99.9), all[len(all)-1])
		pass := pct(99) <= pLatencyMs
		fmt.Printf("  PASS (p99<=20ms)? %v\n", pass)
	}
}
EOF

# ============================ SRVMON (identical to FSS) ============================
cat > srvmon/main.go <<'EOF'
package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
)

type opLat struct {
	Latency int64 `bson:"latency"`
	Ops     int64 `bson:"ops"`
}

type serverSnap struct {
	OpLatencies struct {
		Writes   opLat `bson:"writes"`
		Commands opLat `bson:"commands"`
	} `bson:"opLatencies"`
	Queues struct {
		Execution struct {
			Write struct {
				Out          int32 `bson:"out"`
				Available    int32 `bson:"available"`
				TotalTickets int32 `bson:"totalTickets"`
				NormalPriority struct {
					QueueLength int64 `bson:"queueLength"`
				} `bson:"normalPriority"`
			} `bson:"write"`
		} `bson:"execution"`
	} `bson:"queues"`
	Metrics struct {
		Operation struct {
			WriteConflicts int64 `bson:"writeConflicts"`
		} `bson:"operation"`
	} `bson:"metrics"`
}

func snapshot(ctx context.Context, adm *mongo.Database) (serverSnap, error) {
	var s serverSnap
	err := adm.RunCommand(ctx, bson.D{{Key: "serverStatus", Value: 1}}).Decode(&s)
	return s, err
}

func avgMs(dLat, dOps int64) string {
	if dOps == 0 { return "n/a" }
	return fmt.Sprintf("%.2fms", float64(dLat)/float64(dOps)/1000.0)
}

func main() {
	durSec := 60
	if len(os.Args) > 1 { fmt.Sscan(os.Args[1], &durSec) }
	uri := os.Getenv("MONGO_URI")
	if uri == "" { fmt.Fprintln(os.Stderr, "ERROR: MONGO_URI not set"); os.Exit(1) }
	ctx := context.Background()
	cli, err := mongo.Connect(options.Client().ApplyURI(uri))
	if err != nil { panic(err) }
	defer cli.Disconnect(ctx)
	adm := cli.Database("admin")

	fmt.Println("server opLatencies + writeConflicts + WT write tickets (5s windows):")
	start := time.Now()
	prev, err := snapshot(ctx, adm); if err != nil { panic(err) }
	time.Sleep(5 * time.Second)
	deadline := start.Add(time.Duration(durSec) * time.Second)
	for time.Now().Before(deadline) {
		cur, err := snapshot(ctx, adm)
		if err != nil { fmt.Fprintf(os.Stderr, "  snapshot err: %v\n", err); time.Sleep(5 * time.Second); continue }
		dWriteLat := cur.OpLatencies.Writes.Latency - prev.OpLatencies.Writes.Latency
		dWriteOps := cur.OpLatencies.Writes.Ops - prev.OpLatencies.Writes.Ops
		dCmdLat := cur.OpLatencies.Commands.Latency - prev.OpLatencies.Commands.Latency
		dCmdOps := cur.OpLatencies.Commands.Ops - prev.OpLatencies.Commands.Ops
		dWC := cur.Metrics.Operation.WriteConflicts - prev.Metrics.Operation.WriteConflicts
		wq := cur.Queues.Execution.Write
		fmt.Printf("  t+%ds  write_avg=%s  cmd_avg=%s  wc/s=%d  w_tickets=%d/%d  queued=%d\n",
			int(time.Since(start).Seconds()),
			avgMs(dWriteLat, dWriteOps), avgMs(dCmdLat, dCmdOps),
			dWC/5, wq.Out, wq.TotalTickets, wq.NormalPriority.QueueLength)
		prev = cur
		time.Sleep(5 * time.Second)
	}
}
EOF

echo "=== go mod tidy + build all three binaries ==="
go mod tidy
go build -o perop_bin ./perop && echo "perop_bin OK"
go build -o clientbulk_bin ./clientbulk && echo "clientbulk_bin OK"
go build -o srvmon_bin ./srvmon && echo "srvmon_bin OK"
ls -la perop_bin clientbulk_bin srvmon_bin
echo "=== Build done. Next: ./run_perop.sh or ./run_clientbulk.sh ==="
