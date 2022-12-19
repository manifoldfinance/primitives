# Differential dataflow roadmap

> source https://github.com/frankmcsherry/blog/blob/master/posts/2016-07-26.md

I'm going to take this post to try and outline what I think is an important
direction for differential dataflow, and to explain how to start moving in this
direction. I think I have a handle on most of the path, but talking things out
and explaining them, with examples and data and such, makes me a lot more
comfortable before just writing a lot of code.

The main goal is to support "high resolution" updates to input streams. Right
now, updates to differential dataflow come in batches, and get relatively decent
scaling as long as the batches are not small. While you can cut the size of
batches to improve resolution, increasing the number of workers no longer
improve performance.

It would be _great_, and this write-up is meant to be a first step, to be able
to have input updates timestamped with the nanosecond of their arrival and the
corresponding output updates with the same resolution, while still maintaining
the throughput you would expect for large batch updates.

## The problem

Let's start with a simple-ish, motivating problem to explain what is missing. We
can also use it to evaluate our progress (none yet!), and possibly to tell us
when we are done.

Imagine you are performing reachability queries, an iterative Datalog-style
computation, over dynamic graph data from user-specified starting locations. The
computation is relatively simply written:

```rust
// two inputs, one for roots, one for edges.
let (root_input, roots) = scope.new_input();
let (edge_input, edges) = scope.new_input();

// iteratively expand set of (root, node) reachable pairs.
roots.map(|root| (root, root))
     .iterate(|reach| {

   	     // bring un-changing collections into loop.
   	     let roots = edges.enter(&reach.scope());
         let edges = edges.enter(&reach.scope());

         // join `reach` and `edges` on `node` field.
         reach.map(|(root, node)| (node, root))
       	      .join_map(&edges, |_node, root, dest| (root, dest))
       	      .concat(&roots)
       	      .distinct()
});
```

The result of this computation is a collection of pairs `(root, node)`
corresponding to those elements `root` of `roots`, and those elements `node`
they can reach transitively along elements in `edges`.

Of course, the heart of differential dataflow lies in incrementally updating its
computations. We are interested in what happens to this computation as the
inputs `roots` and `edges` change. More specifically,

1. The `roots` collection may be updated by adding and removing root elements,
   which issue and cancel standing queries for reachable nodes, respectively.

2. The `edges` collection may be updated by adding and removing edge elements,
   which affect the reachable set of nodes from any of the elements of `roots`.

Consider a version of this computation that runs "forever", where the timestamp
type is a `u64` indicating "nanosecond since something". Each change that
occurs, to `edges` or `roots` happens at a likely distinct nanosecond, and so we
imagine many single-element updates to our computation. We don't expect to
actually process them within nanoseconds (would be great, but), but the
nanoseconds units means that corresponding output updates also indicate the
logical nanosecond at which the change happens.

This isn't difficult in differential dataflow: timely dataflow, on which it is
built, does no work for epochs in which no data are exchanged, no matter how
fine grained the measurement. We could use
[Planck time](https://en.wikipedia.org/wiki/Planck_time) if we wanted; our
computation wouldn't run any differently (it might overflow the 64 bit numbers
sooner).

But, this doesn't mean we don't have problems.

### Degradation with time

For now, let's put ten roots into `roots` and load up two million random edges
between one million nodes. We are then going to repeatedly remove the oldest
existing edge and introduce a new random edge in its place. This is a sliding
window over an unbounded stream of random edges, two million elements wide.

Our computation determines the reachable sets for our ten roots, and maintains
them as we change the graph. How quickly does this happen? Here are some
empirical cumulative density functions, computed by capturing the last 100
latencies after each of 100, 1000, 10000, and 100000 updates have been
processed.

![gnp1m](https://github.com/frankmcsherry/blog/blob/master/assets/roadmap/gnp1m.png)

This is all a bit of a tangle, but we see a fairly consistent shape for the
first 100,000 updates. However, there is clearly some degradation that starts to
happen. On the plus side, most of the latencies are still milliseconds at most,
which is pretty speedy. Should we be happy?

Let's look at a slight variation on this experiment, where instead of millions
of edges and nodes we use _thousands_. Yeah, smaller, by a lot. Same deal as
above, latencies at 100, 1000, 10000, and ... urg.

![gnp1k](https://github.com/frankmcsherry/blog/blob/master/assets/roadmap/gnp1k.png)

These curves are very different from the curves above. I couldn't compute the
100,000 update measurement because it took so long.

#### What's going on?

Differential dataflow's internal data structures are append-only, and over the
course of 10,000 updates we are dumping a large number of updates _relative to
the number of nodes_. Back when we had one million nodes, doing 100,000 updates
wasn't such a big deal because on average each node got just a few (multiply by
ten, because of the roots!). With only 1,000 nodes, all of those updates are
being forced onto far fewer nodes, which mean that each node has a much more
complicated history. Unfortunately, to determine what state a node is currently
in, at any point in the computation, we need to examine all of its history.

As the number of updates for each key increases, the amount of work we have to
do for each key increases.

### Resolution and scaling

How about we try to speed things up by adding more workers? Perhaps
unsurprisingly, with single-element updates, multiple workers do not really help
out. At least, the way the code is written at the moment, all the workers chill
out waiting for that single update to get sorted out before moving on to the
next update. As there is only a small amount of work to do, most workers sit on
their hands instead of do productive work.

Let's evaluate this, plus alternatives we might have hoped for. We are going to
do single element updates 10,000 times to the two million edge graph, but we
will also do 10 element updates 1,000 times, and 100 element updates 100 times.
We are doing the same set of updates, just in coarser granularities, leading to
lower resolution outputs.

![batching](https://github.com/frankmcsherry/blog/blob/master/assets/roadmap/batching.png)

The plot above shows solid lines for single-threaded execution and dashed lines
for two-threaded execution. When we have the single-element updates, the solid
line is better than the dashed line (one worker is better than two). When we
have hundred-element updates, the dashed line is better than the solid line (two
workers are better than one). As the amount of work in each batch increases, the
second worker can more productively contribute.

While we can eyeball the latencies and see some trends, what are the actual
throughputs for each of these configurations?

| batch size | one worker | two workers | increase |
| ---------: | ---------: | ----------: | -------: |
|          1 |  1244.96/s |   1297.07/s |   1.042x |
|         10 |  1988.71/s |   2530.23/s |   1.272x |
|        100 |  1563.32/s |   2743.31/s |   1.755x |

Something good seemed to happen for one worker batch size 10 that doesn't happen
to batch size 100; I'm not sure what that is about. But, we see that the second
worker helps more and more with increasing batch sizes. We don't get 2x
improvement, which is partly due to the introduction of data exchange going from
one to two workers (no data shuffling happens for one worker).

#### What's going on?

This isn't too mysterious: processing single elements at a time and asking all
workers to remain idle until each is finished leaves a lot of cycles on the
table. At the same time, lumping lots of updates together improves the
utilization and allows more workers to reduce the total time to process, but
comes at the cost of resolution: we can't see which of the 100 updates had which
effect.

We would love to get the resolution of single-element updates with the
throughput scaling of the batched updates, if at all possible. We'd also like
the _latency_ of the single-element updates, but note that this is not the same
thing as either resolution or throughput.

- **Resolution** is important for correctness; we can't alter the resolution of
  inputs and outputs without changing the definition of the computation itself.

- **Throughput** is the rate of changes we can accommodate without falling over.
  We want this to be as large as possible, ideally scaling with the number of
  workers, so that we can handle more updates per unit time.

- **Latency** is the time to respond to an input update with its corresponding
  output update. The lower the latency the better, but this fights a little
  against throughput.

At the moment, single-element updates focus on latency; workers do nothing
except attend to the most recent single update. Getting great latency would be
excellent, but if it comes at the cost of throughput we might want a different
trade-off.

### Goals

The intent of this write-up is to investigate these problems in more detail,
propose some solutions, and (importantly, for me) come up with a framework for
evaluating the results. There is a saying that "you can't manage what you don't
measure", one corrolary of which is that I'm not personally too motivated to
work hard on code until I have a benchmark for it. With that in mind, here are
two benchmarks that (i) are important, (ii) currently suck, and (iii) could be a
lot better:

1.  **Sustained latency:** For windowed computations (or those with bounded
    inputs, generally), the latency distribution should stabilize with time. The
    latency distribution for 1,000 node 2,000 edge reachability computations
    after one million updates should be pretty much the same as the distribution
    after one thousand updates. Minimize the difference, and report only the
    former.

2.  **Single-update throughput scaling:** The throughput of single-element
    updates should improve with multiple workers (up to a point). The
    single-update throughput for 1,000 node 2,000 edge reachability computations
    should scale nearly linearly with (a few) workers. Maximize the throughput,
    reporting single-element updates per second per worker.

These aren't really grand challenges or anything, especially as I think I know
how to do them already, but goal setting is an important part of getting things
done.

## The problems

There are two main problems that we are going to want to re-work bits of
differential dataflow to fix. There are also some secondary "constraints", which
are currently non-issues but which we could break if we try and be too clever.

To give you a heads up, and to let you skip around, the problems (with links!)
are:

- **[Problem 0: Data structures for high-resolution times](https://github.com/frankmcsherry/blog/blob/master/posts/2016-07-26.md#problem-0-data-structures-for-high-resolution-times)**
  The data structure differential dataflow currently uses to store collection
  data isn't great for high resolution times, even ignoring the more subtle
  performance issues. It works, but it doesn't expect large numbers of times and
  should be reconsidered.

- **[Problem 1: Unbounded increase in latency](https://github.com/frankmcsherry/blog/blob/master/posts/2016-07-26.md#problem-1-unbounded-increase-in-latency)**
  As the computation proceeds, the latencies increase without bound. This is
  because we keep appending in state, and the amount that must be considered to
  evaluate the current configuration grows without bound.

- **[Problem 2: Poor scaling with small updates](https://github.com/frankmcsherry/blog/blob/master/posts/2016-07-26.md#problem-2-poor-scaling-with-small-updates)**
  As we increase the number of workers, we do not get increased throughput
  without also increasing the sizes of batches of input we process. Increases in
  performance come at the cost of more granular updates.

There are some constraints that are currently in place, and we will go through
them to remember what is hard and annoying about just typing these things in.

- **[Constraint 1: Compact representation in memory](https://github.com/frankmcsherry/blog/blob/master/posts/2016-07-26.md#constraint-1-compact-representation-in-memory)**
  The representation of a trace should not be so large that I can't fit normal
  graphs in memory on my laptop. Ideally the memory footprint should be not much
  larger than required to write the data on disk.

- **[Constraint 2: Shared index structures between operators](https://github.com/frankmcsherry/blog/blob/master/posts/2016-07-26.md#constraint-2-shared-index-structures-between-operators)**
  Index structures are currently shared between operators, so that a collection
  only needs to be indexed and maintained once per computation, for each key on
  which it is indexed.

### Problem 0: Data structures for high-resolution times

Each differential dataflow collection is described by a bunch of tuples, each of
which reflect a change described by three things:

- **Data:** Each change that occurs relates to some data. Typically these are
  `(key, val)` pairs, but they could also just be `key` records, or they could
  be even more complicated.

- **Time:** Each change occurs at some logical time. In the simplest case each
  is just an integer indicating which round the change happens in, but it can be
  more complex and is generally only known to be an element from a partially
  ordered set.

- **Delta:** Each change has a signed integer change to the frequency of the
  element, indicating whether the change adds an element or removes an element.

This collection of `(data, time, delta)` tuples needs to be maintained in a form
that allows relatively efficient enumeration of the history of individual data
records: those `(data, time, delta)` tuples matching `data`.

Differential dataflow currently maintains its tuples ordered first by `key`,
then by `time`, and then by `val`. This makes some sense if you imagine that
many changes to `key` occur at the same time, as you can perform per-`time`
logic once per distinct time. In batch-iterative computation, where there is
just one input and relatively few iterations, this is a reasonable assumption.
It is less reasonable for high-resolution times.

Ideally, we would define an interface for the storage layer, so that operators
can be backed by data structures appropriate for high-resolution times, or for
batch data as appropriate. Let's describe what interface the storage should
provide, somewhat abstractly:

1. Accept batches of updates, `(data, time, delta)`.

   This is perhaps obvious, but without this we don't really have a problem.
   Importantly, we should be able to submit _batches_ of updates corresponding
   to multiple `data` and multiple `time` entries. The batch interface
   communicates that the data structure doesn't need to be in an indexable state
   for each element, only once it accepts the batch.

2. Enumerate those `data` associated with a `key`.

   Many operators (e.g. `join` and `group`) drive computation by `key` keys and
   their associated `val` values. One should be able to enumerate values
   associated with a key, preferably supporting some sort of navigation (e.g.
   searching for values).

3. Report the history `(time, delta)` for each `data`.

   The history of `data` is used by many operators to determine (i) the
   cumulative weight at any other `time`, (ii) which times are associated with a
   `key`, which drives when user-defined logic needs to be re-run.

[Constraint #1](https://github.com/frankmcsherry/blog/blob/master/posts/2016-07-26.md#constraint-1-compact-representation-in-memory)
makes life a little difficult for random access, navigation, and mutation, as
these usually fight with compactness. Perhaps less obviously,
[Constraint #2](https://github.com/frankmcsherry/blog/blob/master/posts/2016-07-26.md#constraint-2-shared-index-structures-between-operators)
complicates in-place updating, because multiple readers may share read access to
the same hunk of memory, and something needs to stay true about it.

#### A proposal

My best plan for the moment is something like a log-structure merge trie, which
probably isn't an existing term, but let me explain:

1. We maintain several immutable collections of `((key, val), time, delta)`
   tuples, of geometrically decreasing size. When we add new collections,
   corresponding to an inserted batch, we merge any collections whose sizes are
   within a factor of two, amortizing the merge effort over subsequent
   insertions.

2. Each of the `((key, val), time, delta)` collections is represented as a trie,
   with three vectors corresponding to "keys and the offsets of their values",
   "values and the offsets of their history", and "histories":

   ```rust
   struct Trie<K, V, T> {
   	keys: Vec<(K, usize)>,		// key and offset into self.values
   	values: Vec<(V, usize)>,	// val and offset into self.histories
   	histories: Vec<(T, isize)>,	// bunch of times and deltas
   }
   ```

Adding new batches of data is standard; this type of data structure is meant to
be efficient at writing, with the main (only?) cost being the merging. As the
collections are immutable, this can happen in the background, but needs to
happen at a sufficient rate to avoid falling behind. However, merging feels like
a relatively high-throughput operation compared to a large amount of random
access (computation) that will come with each inserted element. Said
differently, we only merge in data involved in computation, so we shouldn't be
doing more writes than reads.

Reading data out requires indexing into each of the tries to find a target key.
One could look into each of the tries for the key, using something like binary
search, or a galloping cursor (as most operators process keys in some known
order). Another option is to maintain an index for keys, indicating for each the
lowest level (smallest) trie in which the key exists and the key's offset in
that trie's `keys` field. With each `(K, usize)` pair, we could store again an
index of the next-lowest level trie in which the key exists and the key's offset
there.

This allows us to find the keys and their tries with one index look-up and as
many pointer jumps as trie levels in which the key exists. Adding and merging
tries only requires updating the index for involved keys, and does not require
rewriting anything in existing trie layers.

Here is a sketch of the involved structures:

```rust
struct Storage<K,V,T> {
	index: HashMap<K, KeyLoc>,	// something better, ideally
	tries: Vec<Trie<V,T>>,		// tries of decreasing size
}

struct KeyLoc {
	level: usize,				// trie level
	index: usize,				// index into trie.keys
}

struct Trie<V, T> {
	keys: Vec<(K, usizes, KeyLoc)>,	// key, offset into self.values, next key location
	values: Vec<(V, usize)>,		// val and offset into self.histories
	histories: Vec<(T, isize)>,		// bunch of times and deltas
}
```

I think this design makes a good deal of sense in principle, but it remains to
see how it will work out in practice. On the plus side, it doesn't seem all that
complicated at this point, so trying it out shouldn't be terrifying. Also, I'm
much happier with something that works in principle, maybe loses a factor of two
over a better implementation, but doesn't require a full-time employee to
maintain.

The design has a few other appealing features: each of the bits of state are
contiguous ordered hunks of memory,

1. They are relatively easy to serialize to disk and `mmap` back in.

2. Processing batches of keys in order results in one sequential scan over each
   array, good for performance and if we spill to disk.

3. The large unit of data means that sharing between operators is relatively low
   cost (we can wrap each layer in a `Rc` reference count).

You might notice that this doesn't yet meet
[Constraint #2](https://github.com/frankmcsherry/blog/blob/master/posts/2016-07-26.md#constraint-2-shared-index-structures-between-operators),
the requirement that the memory size look something like what it would take to
write the data down compactly. For example, if all times and deltas are
identical (say `0` and `+1`, respectively), the `histories` field will hold a
very large amount of identical `(0,1)` pairs. There are some remedies that I can
think of, and will discuss them below, but for the moment too bad.

### Problem 1: Unbounded increase in latency

Latency increases without bound as the computation proceeds. If we were to look
at memory utilization, we would also see that it increases without bound as the
computation proceeds. Neither of these are good news if you are expecting to run
indefinitely.

This is not unexpected for an implementation whose internal datastructures are
append-only. As a differential dataflow computation proceeds, each operator
absorbs changes to its inputs and appends them to its internal representation of
the input. This representation grows and grows, which means (i) it takes more
memory, and (ii) the operator must flip through more memory to determine the
state at any given logical time.

Let's look at an example to see the issue, and get a hint at how to solve it.

In the reachability example above, we update the query set `roots` by adding and
removing elements. These changes look like

    (root, time_1, +1)
    (root, time_2, -1)

We add an element `root` at some first time, and then subtract it out at some
later time.

Although it was important to have both of these differences, at some point in
the computation, once we have processed everything up through `time_2`, we are
going to be scanning these differences over and over, and they will always
cancel. Not only that, but all of their consequent reachability updates

    ((root, node), (time_1, iter), +1)
    ((root, node), (time_2, iter), -1)

are going to live on as well, despite cancelling completely after `time_2`.
Future changes to `edges` will flip through each of these updates to determine
if they should provoke an output update related to `root`, and while they will
eventually determine that no they shouldn't, they do a fair bit of work to see
this.

#### Compaction

We know that once we have "passed" `time_2` we really don't care about `root`,
do we? At that point, and from that point forward, its updates will just cancel
out.

This is true, and while it is good enough for a system where times are totally
ordered, we need to be a bit smarter with partially ordered times. Martin Abadi
and I did the math out for "being a bit smarter" a few years ago, and I'm going
to have to reconstruct it (sadly, our mutual former employer deleted the work).

In a world with partially ordered times, we talk about progress with
"frontiers": sets of partially ordered times none of which comes before any
others in the set. At any point in a timely dataflow computation, there is a
frontier of logical times defining those logical times we may see in the future:
times greater or equal to a time in the frontier.

Frontiers are what we will use to compact our differences, rather than the idea
of "passing" times.

Any frontier of partially ordered elements partitions the set of all times
(past, present, future) into an equivalence class based on "distinguishability"
in the future: two times are indistinguishable if they compare identically to
every future time:

    t1 == t2 : for all f in Future, t1 <= f iff t2 <= f.

As the only thing we know about times is that they are partially ordered, their
behavior under the `<=` comparison is sufficient to describe each full.
Differences at indistinguishable times can be coalesced into (at most) one
difference.

Let's look at an example. Imagine we have the following updates:

    ((a, b), +1) @ (0, 0)
    ((b, c), +1) @ (0, 1)
    ((a, c), +1) @ (1, 0)
    ((b, c), -1) @ (1, 1)

So, we initially have an `(a,b)` and we generate a `(b,c)` in the first
iteration of some iterative computation, say. Someone then changes our input to
have `(a,c)` in the input, and now we remove `(b,c)` in the second iteration.

Imagine now that our frontier, the lower envelope of times we might yet see in
the computation, is

    { (0, 3), (1, 2), (2, 0) } .

Meaning, we may still see any time that is greater-or-equal to one of these
times. While this does rule out times like `(0,1)` and `(0,2)`, it does _not_
mean that we can just coalesce them. There is a difference between these two
times, in that the possible future time `(2,1)` can tell them apart:

    (0,1) <= (2,1) : true
    (0,2) <= (2,1) : false

So how then do we determine which times are equivalent to which others? Ideally,
we would consult our notes, but this option is not available to us. We can do
the next best thing, which is to look at
[what we did in Naiad's implementation](https://github.com/MicrosoftResearch/Naiad/blob/release_0.5/Frameworks/DifferentialDataflow/LatticeInternTable.cs#L59-L74):

```csharp
/// <summary>
/// Joins the given time against all elements of reachable times, and returns the meet of these joined times.
/// </summary>
/// <param name="s"></param>
/// <returns></returns>
private T Advance(T s)
{
    Debug.Assert(this.reachableTimes != null);
    Debug.Assert(this.reachableTimes.Count > 0);

    var meet = this.reachableTimes.Array[0].Join(s);
    for (int i = 1; i < this.reachableTimes.Count; i++)
        meet = meet.Meet(this.reachableTimes.Array[i].Join(s));

    return meet;
}
```

Ok, this is _NOT_ Rust. C-sharp is object-orientated, and has a `this` keyword
that wraps some state local to whatever "this" is. It turns out "this" is a
table of timestamps, whose values we update as `this.reachableTimes` advances.
This `reachableTimes` thing is how Naiad refers to frontiers: timestamps that
the operator can still receive.

What the code tells us is that to determine what a time `s` should look like
given a frontier, we should join `s` with each element in the frontier, and take
its meet. If you aren't familiar with "join" and "meet", let's review those:

-     The **join** method determines the least upper bound of two arguments. That is,

      a <= join(a,b), and
      b <= join(a,b), and
      for all c: if (a <= c and b <= c) then join(a,b) <= c.

  This may not always exist in a general partial order, so we need to be in at
  least a join semi-lattice (a partial order where join is always defined).

- The **meet** method determines the greatest lower bound of two arguments. That
  is,

      meet(a,b) <= a, and
      meet(a,b) <= b, and
      for all c: if (c <= a and c <= b) then c <= meet(a,b).

  This may not always exist in a general partial order, so we need to be in at
  least a meet semi-lattice (a partial order where meet is always defined).

If both join and meet are defined for all pairs of elements in our partial
order, we have what is called a
"[lattice](<https://en.wikipedia.org/wiki/Lattice_(order)>)". Differential
dataflow should _probably_ require all of its timestamps to be lattices, but at
the moment it just uses least upper bounds. This discussion may prompt the
change to lattices.

For very simple examples of join and meet, consider pairs of integers in which
you compare pairs coordinate wise, and

    (a1,b1) <= (a2, b2) iff a1 <= a2 && b1 <= b2 .

The join (least upper bound) of two elements is the pair with the
coordinate-wise maximums, and the meet (greatest lower bound) of two elements is
the pair with the coordinate-wise minimums.

#### An example (redux)

Let's look at our example again. We have updates:

    ((a, b), +1) @ (0, 0)
    ((b, c), +1) @ (0, 1)
    ((a, c), +1) @ (1, 0)
    ((b, c), -1) @ (1, 1)

and perhaps the frontier is currently

    { (0, 3), (1, 2), (2, 0) } .

We can update each of our times using the "meet of joins" rule above, here

    time -> meet(join(time, (0,3)), join(time, (1,2)), join(time, (2,0)))

For each of our times, we get the following updates

    (0,0) -> meet((0,3), (1,2), (2,0)) = (0,0)
    (0,1) -> meet((0,3), (1,2), (2,1)) = (0,1)
    (1,0) -> meet((1,3), (1,2), (2,0)) = (1,0)
    (1,1) -> meet((1,3), (1,2), (2,1)) = (1,1)

It doesn't seem like this changed anything, did it? Well, all four times can
still be distinguished in the future. The future time `(0,3)` can tell the
difference between times that differ in the first coordinate, and the future
time `(2,0)` can distinguish between the times that differ in the second
coordinate.

Imagine our frontier advances, finishing input epoch zero, and becomes:

    { (1, 2), (2, 0) } .

Now we get different results when we advance times, as the first term drops out
of each meet.

    (0,0) -> meet((1,2), (2,0)) = (1,0)
    (0,1) -> meet((1,2), (2,1)) = (1,1)
    (1,0) -> meet((1,2), (2,0)) = (1,0)
    (1,1) -> meet((1,2), (2,1)) = (1,1)

Ooooo! Now some things are starting to look the same! The two `(b,c)` updates in
times `(0,1)` and `(1,1)` can now cancel.

Imagine instead we closed our input, removing the possibility of new input
epochs, setting the frontier to

    { (0,3), (1,1) }

Now we get even more contraction, where we can contract across iterations as
well as rounds of input:

    (0,0) -> meet((0,3), (1,1)) = (0,1)
    (0,1) -> meet((0,3), (1,1)) = (0,1)
    (1,0) -> meet((1,3), (1,1)) = (1,1)
    (1,1) -> meet((1,3), (1,1)) = (1,1)

Now we are able to aggregate updates across iterations, rather than epochs. In
our example it doesn't actually change anything, but in an iterative computation
with closed inputs it means that we can update "in place" rather than retaining
the history of all iterations.

If both happen, and the frontier becomes just

    { (1,1) }

all of the updates we have can be aggregated. The meet of joins logic works
seamlessly for all modes.

#### Proving things

Imagine we have a frontier F, is it true that the technique above (take the
meets of joins) is correct? What would that even mean? Here is a correctness
claim we might try to prove:

    Claim (correctness):

    For any frontier F and time s, let

        t = meet_{f in F} join(f,s).

    then for all g >= F, we have s <= g iff t <= g.

Let's prove the `iff` in two parts,

1.       **If `t <= g`, then `s <= g`: **

    For any `f` we have that `s <= join(s,f)`, but in particular for those
    `f in F`. Because `s` is less than all terms in the meet, and by the main
    property of meets, we have that `s <= t` as `t` is that meet. We combine
    this with the assumption `t <= g` and reach our conclusion using
    transitivity of `<=`.

2.  **If `s <= g`, then `t <= g`: **

    By assumption, `g` is greater than or equal to some element `f in F`. As
    such, `join(s,f) <= g`, by the main property of joins (as both `s <= g` and
    `f <= g`). The meet operation always produces an element less or equal to
    its arguments, and because the definition of `t` has at least the
    `join(s,f)` term in its meets, we conclude that `t <= g`.

Wow proofs are fun! Let's do another one!

How about proving that this contraction is optimal? What would that even mean?
Here is an optimality claim we might try and prove:

    Claim (optimality):

    For two times s1 and s2, if for all g >= F we have that

    	s1 <= g iff s2 <= g ,

    then meet_{f in F} join(f,s1) == meet_{f in F} join(f,s2).

What we are saying here is that if two times are in fact indistinguishable for
all future times, then they will result in the same surrogate times `t1` and
`t2`. As we cannot correctly equate two times that are not indistinguishable,
this would be optimality.

Let's try and prove this.

**Proof deferred.** I couldn't remember how to prove optimality, or even if we
did prove it. Sigh. However, I asked Martin Abadi what he thought, and he came
back with the following alternate optimality statement, which I'm going to call
"maximality" to keep it clear from the previous claim.

    Claim (maximality):

    For two times s and t', if for all g >= F we have that

    	s <= g iff t' <= g

    then

    	t' <= meet_{f in F} join(f,s).

What this claim says is that if you were thinking of contracting `s` to any time
`t'` other than `meet_{f in F} join(f,s)`, your `t'` will have to be less or
equal to ours. Our choice is "maximal", in that sense. This proves that we've
done as well as we can, but it doesn't prove that if `s1` and `s2` are
indistinguishable they result in the same contraction. Yet!

Here is Martin's proof (mutatis mutandis):

For all `f` (but in particular `f in F`) we have that `s <= join(f,s)` by the
properties of join, and because `join(f,s) >= F` we have by assumption that
`t' <= join(f,s)`. As this holds for all `f in F`, `t'` must also be less or
equal to the meet of all these terms, by the main property of meet. Done!

Now we can prove optimality, using maximality as help.

First, let's define

    t1 = meet_{f in F} join(f,s1), and
    t2 = meet_{f in F} join(f,s2).

Now, we have assumed that `s1` and `s2` are indistinguishable in the future of
`F`, and we know by correctness that `s1` and `t1` are similarly
indistinguishable, as are `s2` and `t2`. This means that `s1` and `t2` are
indistinguishable, as are `s2` and `t1`. Applying each of these observations
with maximality, we conclude that

    t1 <= meet_{f in F} join(f,s2), and
    t2 <= meet_{f in F} join(f,s1).

However, the right hand sides are exactly `t2` and `t1`, respectively, and if
each of `t1` and `t2` are less or equal to each other, they must be the same
(the "antisymmetry" property of a partial order). Done!

Proofs are still fun! Let's hope it's actually true.

#### Implementation

We now have an awesome rule for compacting differences, by advancing timestamps
using the rule from up above:

    advance(s,F) = meet_{f in F} join(s,y) .

We can apply this rule whenever we get a chance to rewrite bits of internal
state. Our optimality result tells us that as long as we apply this rule
regularly enough, we should be able to cancel any indistinguishable updates.

For various reasons, including compaction, we will make sure we take this
opportunity regularly. In the log-structured merge thing up above, each time we
do a merge we can write new times out after subjecting them to this change.

In principle, we could also use this rule to rewrite times within layers of the
merge trie, though I'm a bit hesitant to do that without thinking harder about
the implications of departing from the immutable realm.

### Problem 2: Poor scaling with small updates

As we increase the number of workers, we hope to see a corresponding improvement
in performance. This improvement can take a few different forms:

-     **Weak scaling:**

  As the number of workers increases, the amount of work that can be performed
  in a fixed time increases.

  As best as I understand, differential dataflow does a fine job with weak
  scaling: more workers can do more work in a fixed amount of time. Increasing
  the amount of work does not need to increase the amount of coordination, as
  long as the number of batches do not increase. The downside here is that

-     **Strong scaling:**

  As the number of workers increases, the amount of time taken to perform a
  fixed amount of work decreases.

  Adding more workers does not necessarily decrease the amount of time to
  perform a fixed amount of work. In the limit, when each batch has just a
  single record, the existence of additional workers simply does not offer
  anything of use; the single record goes to one worker who is then the only
  worker able to perform productive computation.

Lots of systems do weak scaling pretty well, and strong scaling up to a point.
While we want as much strong scaling as possible, there is only so fast we can
hope to go (with me writing all the code).

#### High-resolution timestamps

Rather than try and get excellent strong scaling, our somewhat more modest goal
is to develop weak scaling without altering the resolution of timestamps in
differential dataflow. That is, we will accept inputs at the same frequency as a
strongly scaled system (high resolution) and produce outputs with the same
frequency, but we only need to sustain a high throughput rather than low
latency.

For any example of what I'm talking about, think about a sequence of ten
updates:

    (datum_0, 0, +1)
    (datum_1, 1, +1)
    ..
    (datum_9, 9, +1)

In our current implementation, these each have distinct times, and go into
distinct input batches. Each worker worries about the completion of each batch
independently, and doesn't get started on batch 7 until all batches up to and
including batch 6 have been confirmed processed.

It doesn't have to work this way (and doesn't, in some other systems).

Timely dataflow certainly allows for multiple times in flight, and if we put all
ten messages into the system and announce "done with rounds `0-9`", each
differential dataflow operator will pick up various messages, let's say a worker
picks up `datum_7`, and receives word from timely dataflow that all inputs up
through round `9` are accounted for. The work isn't all done yet, but the
operator now knows enough to get processing.

Conceptually, we are going to take this approach, with some implementation
details fixed.

Timely dataflow's progress tracking machinery gets stressed out proportional to
the number of distinct times that you use. Each distinct time needs to be
announced to all other participants, so even if there is just one data record
there would be `#workers` control messages sent out. This means that we
shouldn't really send records at individual times. In addition, all sorts of
internal buffering and such are broken on timestamp boundaries; all channel
buffers get flushed, that sort of thing. We'd really like to avoid that.

Fortunately, there is something simple and smart to do, lifted from timely
dataflow's logging infrastructure. Rather than have each time with a distinct
timestamp, we use just the smallest timestamp and send several records whose
actual times are presented as data. For example,

    ((datum_0, 0), 0, +1)
    ((datum_1, 1), 0, +1)
    ..
    ((datum_9, 9), 0, +1)

Here we've sent the same data all with timestamp zero, but we have provided
enough information to determine the actual time for each record.

Let's call the actual timely dataflow timestamp the "message timestamp"; this is
the one that is all zeros. Let's call the embedded timestamp the "data
timestamp"; this ranges from zero up to nine in this example. The choice to have
each data timestamp in the future of the message timestamp results in two
important properties:

1. Operators receive messages with a message timestamp that allows them to send
   messages with received data timestamp. Operators can safely "advance" any
   capability they hold, and in particular they can advance the message
   timestamp capability to be a capability for any data timestamp.

2. When timely guarantees that no messages will arrive with message timestamp
   `time`, the same must also true for data timestamp `time`. This ensures that
   any logic based on timely dataflow progress statements can still be effected.

What we've done here is embed a higher-resolution timestamp in a
lower-resolution timestamp, using the former for application logic and the
latter for progress logic. We haven't committed to any particular difference
between the two, and we seem to be at liberty to lower the resolution for
progress tracking as we see fit.

The downside to lower-resolution progress tracking is that other workers don't
learn as quickly that they can make forward progress. You might be sitting on a
message with message timestamp `0` and a record with data timestamp
`10_000_000`, which is totally safe and correct, but really annoying to all the
other workers who are waiting to see if you produce a message with message and
data timestamp `0`. One can imagine lots of policies to address this, so let's
name a few.

##### Millisecond resolution

One very simple scheme fixes the lower-resolution timestamp to be something like
"milliseconds" and has the data timestamp indicate the remaining fractional
millisecond, giving us nanosecond accuracy at the data timestamp level.

This approach has one very appealing property, which is that because all workers
use the same scaling, when timely dataflow indicates that time `i` has completed
you know that all times up to `i+1` are complete. Not just `i` milliseconds, but
anything strictly less than `i+1` milliseconds.

The downside here is lack of flexibility. Perhaps in a millisecond we can
accumulate thousands of records; we will have to wait for the millisecond to
expire before we start processing them.

##### Variable resolution

A more optimistic approach might pay attention to how much data is being sent,
and refresh the message timestamp every 1024 records it sends, or something
similarly chosen to amortize the amount of progress traffic that will result
against the data being sent. This ensures that there is at least a certain
amount of work in each batch for each other worker.

One must use a bit of care here to ensure that the timestamps are a coarsening
of some common time. It would be too bad if one operator had relatively few
records to ingest, and advanced times at a slower rate than other operators.
Rather, each should probably have some common notion of time, and when it is
time to advance the low-resolution timestamp each worker consults the common
time and leaps to its now current value.

The downside here is less information about what progress information from
timely dataflow means. Whereas up above, an indication that time `i` was
complete meant up to `i+1`, here it means no such thing.

#### Operator implementations

Differential dataflow's operator implementations currently act "time-at-a-time",
maintaining a list of timestamps they should process and acting on each in turn.
What the operator does depends on the operator, but it typically involves
looking at the history for certain keys, up to and including the timestamp. The
"time-at-a-time" discipline works well enough if there are few times, but when
there are as many timestamps as there are data records, it needs a bit more
thought.

The "time-at-a-time" discipline does maintain an important property, that each
key processes its timestamps according to their partial order. We can still
maintain this property if we want to retire a large batch of data timestamps at
once, roughly as:

1. Identify the subset of unprocessed `((data, dtime), mtime, delta)` tuples for
   which `dtime` is not greater or equal to any element in the operator's input
   frontier (the condition normally used for `mtime`).

2. Group this subset by `key`, and order within each key respecting the partial
   order on `dtime`.

3. For each `(key, dtime)` pair, do the thing the operator used to do for each
   `(mtime, key)` pair.

One advantage this new approach has is that despite a large number of times to
process, we still make just one sequential scan through the keys, resulting in
at most one scan through the collection store.

There are likely to be an abundance of other subtle issues about operator
implementations, which I can't yet foresee. This is one of the advantages of
writing code though, rather than just speculating. You get to find out!

#### Timely dataflow

It would be great for timely dataflow to support lower-resolution timestamps for
progress tracking natively. It isn't obvious that there is one correct way to do
it, so for now we are going to try it out "user mode" style. Perhaps we will
learn something about it (e.g. "not worth it") that will inform a timely
adoption.

### Constraint 1: Compact representation in memory

A collection represents a set of tuples of type `((Key, Val), Time, isize)`. If
we were to write them down, the space requirements would be

    size_of::<((Key, Val), Time, isize)>() * #(distinct (key,val,time)s)

because any tuples with the same `(key,val,time)` entries can be coalesced.

But simply writing down the tuples is not the most efficient way to represent
them. We have seen above the "trie" representation, which sorts tuples and
compresses out common prefixes. For example, the trie representation would
require

      size_of::<(Key, usize)>() * #(distinct keys)
    + size_of::<(Val, usize)>() * #(distinct (key,val)s)
    + size_of::<(Time, isize)>() * #(distinct (key,val,time)s)

This can be much smaller than the raw tuple representation. It has other
advantages, like clearly indicating where key and value ranges start and stop,
which means our code doesn't constantly have to check.

In principle, the data can be much smaller still in some not-uncommon cases.
When the data are static, for example, we have no need of the `(time, isize)`
entries because nothing changes. Even when the data are not static, but have a
large number of entries have timestamps that can be contracted to the same
timestamp, most of the data do not require `(time, isize)` entries.

Economies like this can be accommodated using alternate trie representations.
Relatively few distinct timestamps are well accommodated by a trie for data
structured as `(time, (key, val), delta)`, organized first by time. This type of
arrangement has the annoyance that `key` data are multiple locations, and must
be merged in order to determine cumulative counts at any time. This is not such
a pain for few times, as we were going to need to merge the geometrically sized
trie layers anyhow, but obviously more difficult and less efficient when the
number of times is large.

At the moment, I don't have particularly great thoughts on choosing between
these representations other than to try and have a solid trait hiding the
specifics, behind which we can put several implementations. With some luck, we
could even have composite implementations that wrap a few implementations and
drop tuples into the one best suited to represent them. But decisions that
prevent something like this seem like poor ideas.

### Constraint 2: Shared index structures between operators

Several computations re-use the same collection indexed the same way. For
example, the "people you may know" query from the recent
[differential dataflog post](https://github.com/frankmcsherry/blog/blob/master/posts/2016-06-21.md),
which looks like so:

```rust
// symmetrize the graph, because they do that too.
let graph = graph.map(|(x,y)| (y,x)).concat(&graph);

graph.semijoin(&query)
     .map(|(x,y)| (y,x))
     .join(&graph)
     .map(|(y,x,z)| (x,z))
     .filter(|&(x,z)| x != z)
     // <-- put antijoin here if you had one
     .topk(10)
```

The collection `graph` is used twice; both times its edge records
`(source, target)` are keyed by `source`. The code as written above with have
both `semijoin` and `join` create and maintain their own indexed copies of the
data.

We can be less wasteful by explicitly managing the arrangement of data into
indexed collections, and the sharing of those collections between operators.
Each of `semijoin` and `join` internally use differential's `arrange` operator,
which takes a keyed collection of data and returns an `Arranged`, which contains
a reference counted pointer to the collection trace the arrange operator
maintains. Because the collection is logically append-only, the sharing can be
made relatively safe (there are rules on how you are allowed to interpret the
contents).

Explicitly arranging and then re-using the arrangements, the code above looks
like (note: arrangement not currently optimized for visual appeal):

```rust
// symmetrize the graph
let graph = graph.map(|(x,y)| (y,x)).concat(&graph);

// "arrange" graph, because we'll want to use it twice the same way.
let graph = graph.arrange_by_key(|k| k.clone(), |x| (VecMap::new(), x));
let query = query.arrange_by_self(|k: &u32| k.as_u64(), |x| (VecMap::new(), x));

// restrict attention to edges from query nodes
graph.join(&query, |k,v,_| (v.clone(), k.clone()))
     .arrange_by_key(|k| k.clone(), |x| (VecMap::new(), x))
     .join(&graph, |_,x,y| (x.clone(), y.clone()))
     .map(|(y,x,z)| (x,z))
     .filter(|&(x,z)| x != z)
     // <-- put antijoin here if you had one
     .topk(10)
```

There is some excessive arrangement going on (e.g. `query` and the results of
the first `join`) because the arranged operators only work on pairs of
arrangements. This could be cleaned up if important, but it is assumed you know
a bit about what you are doing at this point.

If all of the code above makes little sense, it boils down to: whatever we do
with our collection data structure, we need to worry that multiple operators may
be looking at the same data.

For example, in the context of one operator we can easily speak about "the
frontier" and do compaction based on this information. When multiple operators
are sharing the same data, there is no one frontier; there is a set of
frontiers, or something like that. It can all be made to work (mostly you just
union together the frontiers with `MutableAntichain`), but some attention to
detail is important.

## Conclusions

This is a pretty beefy write-up, and possibly more for my benefit than for yours
(maybe I should have said that at the beginning; I've most realized it here at
the end, though). I'd really like to lay out the criteria for a successful data
structure and maintenance strategy more clearly, but there are lots of
constraints that come together. For now, I think it is time to start trying it
out and seeing what goes horribly wrong. Then I can tell you about that.
