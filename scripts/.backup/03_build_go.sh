#!/usr/bin/env bash
# 03_build_go.sh — write the two Go harness sources and build both binaries.
#   peropdiag_bin  : 4 separate ops per ACID txn (no bulkWrite) + warmup-excluded percentiles
#   clientbulk_bin : MongoDB 8.0 client-level bulkWrite (4 collections, 1 round trip)
# Both read params from CLI args: <sessions> <target_tps> <duration_s>
# and read pool sizes + warmup from env vars (MIN_POOL, MAX_POOL, WARMUP_SEC).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin

mkdir -p "$GO_DIR/perop" "$GO_DIR/clientbulk"
cd "$GO_DIR"
[[ -f go.mod ]] || go mod init acidbench

# ---------- shared constants block (kept identical between variants) ----------
read -r -d '' CONSTS <<'EOF' || true
const (
	dbName       = "acid_bench"
	numCards     = 1_000_000
	numMerchants = 5_000
	cardBuckets  = 1
	merchBuckets = 256
	hotFrac      = 0.02
	hotShare     = 0.80
	pLatencyMs   = 20.0
)

var errInsufficient = fmt.Errorf("insufficient_funds")

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
EOF

# ============================ PER-OP VARIANT ============================
cat > perop/main.go <<EOF
package main

import (
	"context"
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
	cardCtr := db.Collection("card_op_counter"); merchCtr := db.Collection("merchant_op_counter")
	txnOpts := options.Transaction().SetWriteConcern(writeconcern.Majority())

	var wg sync.WaitGroup
	latCh := make([][]float64, sessions); committed := make([]int, sessions); errs := make([]int, sessions)
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
				cardID := r.Intn(numCards); merchID := pickMerchant(r); amount := int64(r.Intn(100)+1)
				cb := r.Intn(cardBuckets); mb := r.Intn(merchBuckets)
				t0 := time.Now()
				txnCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
				_, txErr := sess.WithTransaction(txnCtx, func(sc context.Context) (interface{}, error) {
					res, e := cards.UpdateOne(sc, bson.M{"_id": cardID, "balance": bson.M{"\$gte": amount}}, bson.M{"\$inc": bson.M{"balance": -amount}})
					if e != nil { return nil, e }
					if res.MatchedCount == 0 { return nil, errInsufficient }
					if _, e = ledger.InsertOne(sc, bson.M{"card_id": cardID, "merchant_id": merchID, "amount": amount, "ts": time.Now()}); e != nil { return nil, e }
					if _, e = cardCtr.UpdateOne(sc, bson.M{"_id": fmt.Sprintf("%d:%d", cardID, cb)}, bson.M{"\$inc": bson.M{"count": 1}}); e != nil { return nil, e }
					if _, e = merchCtr.UpdateOne(sc, bson.M{"_id": fmt.Sprintf("%d:%d", merchID, mb)}, bson.M{"\$inc": bson.M{"count": 1}}); e != nil { return nil, e }
					return nil, nil
				}, txnOpts)
				cancel()
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
	report("PER-OP", latCh, committed, errs, time.Since(start).Seconds(), float64(warmupSec))
}

func report(name string, latCh [][]float64, committed, errs []int, elapsed, warmup float64) {
	var all []float64; tc, te := 0, 0
	for i := range latCh { all = append(all, latCh[i]...); tc += committed[i]; te += errs[i] }
	sort.Float64s(all)
	win := elapsed - warmup; if win <= 0 { win = elapsed }
	pct := func(p float64) float64 { if len(all)==0 {return 0}; idx:=int(p/100*float64(len(all))); if idx>=len(all){idx=len(all)-1}; return all[idx] }
	fmt.Println("==================================================")
	fmt.Printf("GO %s STEADY-STATE (%.1fs total, %.1fs measured)\n", name, elapsed, win)
	fmt.Println("==================================================")
	fmt.Printf("  committed (post-warmup): %d  windowed TPS: %.0f  errors: %d\n", tc, float64(tc)/win, te)
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
	latCh := make([][]float64, sessions); committed := make([]int, sessions); errs := make([]int, sessions)
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
				cardID := r.Intn(numCards); merchID := pickMerchant(r); amount := int64(r.Intn(100)+1)
				cb := r.Intn(cardBuckets); mb := r.Intn(merchBuckets)
				t0 := time.Now()
				txnCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
				_, txErr := sess.WithTransaction(txnCtx, func(sc context.Context) (interface{}, error) {
					writes := []mongo.ClientBulkWrite{
						{Database: dbName, Collection: "cards",
							Model: mongo.NewClientUpdateOneModel().
								SetFilter(bson.M{"_id": cardID, "balance": bson.M{"\$gte": amount}}).
								SetUpdate(bson.M{"\$inc": bson.M{"balance": -amount}})},
						{Database: dbName, Collection: "txn_ledger",
							Model: mongo.NewClientInsertOneModel().
								SetDocument(bson.M{"card_id": cardID, "merchant_id": merchID, "amount": amount, "ts": time.Now()})},
						{Database: dbName, Collection: "card_op_counter",
							Model: mongo.NewClientUpdateOneModel().
								SetFilter(bson.M{"_id": fmt.Sprintf("%d:%d", cardID, cb)}).
								SetUpdate(bson.M{"\$inc": bson.M{"count": 1}})},
						{Database: dbName, Collection: "merchant_op_counter",
							Model: mongo.NewClientUpdateOneModel().
								SetFilter(bson.M{"_id": fmt.Sprintf("%d:%d", merchID, mb)}).
								SetUpdate(bson.M{"\$inc": bson.M{"count": 1}})},
					}
					res, e := cli.BulkWrite(sc, writes, options.ClientBulkWrite().SetOrdered(true))
					if e != nil { return nil, e }
					if res.MatchedCount == 0 { return nil, errInsufficient }
					return nil, nil
				}, txnOpts)
				cancel()
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
	report("CLIENT-BULK", latCh, committed, errs, time.Since(start).Seconds(), float64(warmupSec))
}

func report(name string, latCh [][]float64, committed, errs []int, elapsed, warmup float64) {
	var all []float64; tc, te := 0, 0
	for i := range latCh { all = append(all, latCh[i]...); tc += committed[i]; te += errs[i] }
	sort.Float64s(all)
	win := elapsed - warmup; if win <= 0 { win = elapsed }
	pct := func(p float64) float64 { if len(all)==0 {return 0}; idx:=int(p/100*float64(len(all))); if idx>=len(all){idx=len(all)-1}; return all[idx] }
	fmt.Println("==================================================")
	fmt.Printf("GO %s STEADY-STATE (%.1fs total, %.1fs measured)\n", name, elapsed, win)
	fmt.Println("==================================================")
	fmt.Printf("  committed (post-warmup): %d  windowed TPS: %.0f  errors: %d\n", tc, float64(tc)/win, te)
	if len(all) > 0 {
		fmt.Printf("  median %.2f  p95 %.2f  p99 %.2f  p99.9 %.2f  max %.2f\n",
			pct(50), pct(95), pct(99), pct(99.9), all[len(all)-1])
		pass := pct(99) <= pLatencyMs
		fmt.Printf("  PASS (p99<=20ms)? %v\n", pass)
	}
}
EOF

echo "=== go mod tidy + build both binaries ==="
go mod tidy
go build -o perop_bin ./perop && echo "perop_bin OK"
go build -o clientbulk_bin ./clientbulk && echo "clientbulk_bin OK"
ls -la perop_bin clientbulk_bin
echo "=== Build done. Next: ./run_perop.sh or ./run_clientbulk.sh ==="
