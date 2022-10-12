## High resolution, high throughput (pt 2)

> source:
> https://raw.githubusercontent.com/frankmcsherry/blog/master/posts/2017-03-01.md

This post is about the second of two issues I outlined a while back in a
[differential dataflow roadmap](https://github.com/frankmcsherry/blog/blob/master/posts/2016-07-26.md).
I've recently written a bit about the first issue,
[performance degradation over time](https://github.com/frankmcsherry/blog/blob/master/posts/2017-02-11.md),
and steps to ameliorate the issue. That seems to be mostly working now, and I'll
write a bit more about that as it settles.

Instead, we'll talk in this post about the second concern: with fine-grained
updates, perhaps just a few updates per timestamp, additional workers do not
increase the throughput of update processing (and they mostly slow it down).

Stealing
[a figure from the roadmap post](https://github.com/frankmcsherry/blog/blob/master/posts/2016-07-26.md#resolution-and-scaling),
let's look at doing 10,000 updates to a reachability computation with two
million edges, but batching the 10,000 updates three different ways: one, ten,
and one hundred updates at a time:

![batching](https://github.com/frankmcsherry/blog/blob/master/assets/roadmap/batching.png)

The solid lines are the distributions of single-worker latencies, and the dotted
lines are the distributions of two-worker latencies. Visually, the second worker
helps when we have larger input batches and hurts when we have smaller input
batches. In fact, the second worker helps enough on the tail (up at the top of
the plot) that it always gives a throughput increase, but this seems like good
luck more than anything. We would like to see curves that look more like the
rightmost pair.

We would love to get the throughput scaling of larger batch sizes, so why not
always work with large batch sizes? The single-element updates provide something
valuable: very precise information about which input changes lead to which
output changes. By lumping all updates together in a larger batch, we lose
resolution on the effects of the changes. We have to dumb down the computation
to get the performance benefits, and that sucks.

In this post, I'll explain the plan to fix this.

### A tale of three loops

Imagine you were asked to hand-write a program that gets provided with a
timestamped sequence of edge changes (additions, deletions) and you need to
provide the corresponding timestamped changes to the number of nodes at each
distance from node zero.

That is, the input looks a bit like:

     edge 	change 	 time
    (0,3)       +1      0
    (0,2)       +1      5
    (2,3)       +1     10
    (0,3)       -1     11

and your output should look something like

    dist   change   time
       1       +1      0
       1       +1      5
       1       -1     11
       2       +1     11

where these counts are (I hope) the correct changes in counts for the distances
in the graph. Let me know if they are not.

---

As an exercise, actually imagine this. How _would_ you structure your
hand-written program?

---

If I had to guess (and I do), I would guess that most people would write a
program that foremost (i) iterates forward over timestamps, for each time (ii)
iterates over distances from the root, and for each depth (iii) iterates over
reachable nodes and their edges to determine the reachable set of the next
depth.

That is, a program that looks roughly like

    foreach time
        foreach depth (until converged)
            foreach node at depth
                set depth of neighbors to at most depth+1

This program seems totally fine, and I suspect a normal computer scientist will
understand it better than the sort of loop we are going to end up with. To be
totally clear, we aren't going to change the written program at all, we are just
going to execute our program differently. But, if we had to write a program to
explain how the execution works, it would look like this:

    foreach depth (until converged)
        foreach node at depth
            foreach time
                set depth of neighbors at time to at most depth+1

Oh geez. Why can't we just write normal programs for once, huh?

Let's walk through the loop ordering above, using our example just above. Recall

     edge 	change 	 time
    (0,3)       +1      0
    (0,2)       +1      5
    (2,3)       +1     10
    (0,3)       -1     11

Now, we do "time" last, and we do iteration over depth first. So, that means
that we start with the depth 0 nodes. As it turns out there is just one, the
root (node `0`). We iterate over its edges, and determine which neighbors are
reachable at which times, and offer them "depth 1". I think they are:

    (3,1)	    +1      0
    (2,1)       +1      5
    (3,1)       -1     11

This is all we do for the first depth. We are now ready to head in to the next
depth, which is depth 1. These nodes (and their history) is highlighted just
above. When we line this up with edges, we get proposals for depth 2:

    (3,2)       +1     10

Now, this proposal is mostly uninteresting to node `3`, except come time `11`.
At that time, node `3` does actually end up with depth 2, and so we want to do
another round of iteration. But, node `3` has no outgoing edges so there isn't
anything to do.

Nothing in this execution required us to perform work in time order, except
possibly within a `(depth, key)` pair. We could literally take the whole input
history, if we had access to it, and compute the entire output history, doing
the computation depth-by-depth.

This is possible only because we have chosen to map functional computations
across input streams. This restriction on our computational model turns in to a
flexibility in how we execute the computation. Isn't it just delightful when
that happens?

### Why would we do this?

We can apparently pivot around iterative algorithms so that rather than
time-by-time, we do rounds of iterations. Why would we do that?

There are a few reasons I can think of, and they kinda boil down to the same
reason: the only sense in which data-parallel computation needs to wait on input
times is that work should be done in-order for each key.

1.  **Each distinct timestamp is some serious overhead in timely dataflow.**

    This is really annoying. Each distinct timestamp results in all of the
    timely dataflow workers having a little chat. These chats can be boxcar'd
    together, but we are sending bytes of coordination traffic around for each
    distinct time. If there is one record for each time, we would be sending
    much more coordination traffic than data traffic. If we only need to send
    progress traffic for each iteration, rather than each (round, iteration), we
    cut out untenable overhead.

2.  **Workers can proceed independently on decoupled times, scaling better.**

    When we worry about times _last_, workers can get more done without having
    to coordinate. This means workers end up with larger hunks of work to
    perform before they need to wait on others, and generally higher
    utilization, and possibly higher throughput (we'll have to see).

3.  **Workers can re-order work across times to increase locality.**

    Even with a rich and complicated history of updates, workers can sort the
    entire collection by key and do only one scan of key-indexed state. For each
    key there may be many times to consider (in order!), but the worker only
    needs to visit each key once, and in whichever order is most convenient.

There might be a few other cool reasons. Each one is an opportunity for me to
screw things up.

### Making this happen

What would it take to let us do this sort of transformation on iterative
computations? Run batches of input changes concurrently, before we have finished
all of the iterations of earlier batches? What black magic would we need to
summon this pow

Actually, timely dataflow already does this.

Ok, ok. Let's remind ourselves about our reachability computation, which
iteratively joins current distances with edges to propose new distances to each
neighbor, followed by minimizing over the proposed distances for each node:

```rust
    // initialize roots as reaching themselves at distance 0
    let nodes = roots.map(|x| (x, 0));

    // repeatedly update minimal distances each node can be reached from each root
    nodes.iterate(|inner| {

        let edges = edges.enter(&inner.scope());
        let nodes = nodes.enter(&inner.scope());

        // propose dist+1 to neighbors, take mins.
        inner.join_map(&edges, |_k,l,d| (*d, l+1))
             .concat(&nodes)
             .group(|_, s, t| t.push((s[0].0, 1)))
    })
```

Before we do anything, let's add one line after the `group`:

```rust
	.inspect_batch(|t,_| println!("time: {:?}", t))
```

This is going to tell us each time we see a batch of data produced by the
`group` operator (the "min" on depths), and at what logical time we see it. It
should clue us in to how the computation is actually being executed.

The code above is just the definition of the computation; we can run it a few
different ways.

#### Way 1: One update at a time

Let's start with the traditional way we run these computations: we introduce a
change to an input edge, adding a new edge and removing an old edge, and we then
run the computation until the output reflects that change. In our timely code we
might write something like:

```rust
for round in 0 .. rounds {
    // sliding window, let's pretend ...
    graph.send((edges[edge_count + round], 1));
    graph.send((edges[round], -1));

    // advance input and run.
    graph.advance_to(round + 1);
    computation.step_while(|| probe.lt(&graph.time()));
}
```

Here we push some changes into the computation, we advance the `graph` input
(important!), and then we let the computation run until our `probe` (definition
not shown) tells us that our output has caught up to the new input round.

Advancing the input is very important. This is what reveals to timely dataflow
that there will be no more input data with whatever timestamps have been left
behind, which is what allows it to pass this information along to differential
dataflow operators. Then they get to go and do some work.

Advancing is also what tells our `probe` that there can't be any more output.
For homework, convince yourself that this version of the code doesn't work:

```rust
for round in 0 .. rounds {
    graph.advance_to(round);
    graph.send((edges[edge_count + round], 1));
    graph.send((edges[round], -1));
    computation.step_while(|| probe.le(&graph.time()));
}
```

Back to breadth-first search and depth computation. I'm going to run the
computation one update at a time for ten rounds, on a graph with 100 nodes and
100 edges, like so:

    cargo run --example bfs -- 100 100 1 10

This produces a bunch of output times, each of the form
`((Root, round), iteration)`:

    time: ((Root, 0), 0)
    time: ((Root, 0), 1)
    time: ((Root, 0), 2)
    time: ((Root, 0), 3)
    time: ((Root, 0), 4)
    time: ((Root, 2), 4)
    time: ((Root, 2), 5)
    time: ((Root, 5), 2)
    time: ((Root, 5), 3)
    time: ((Root, 7), 3)
    time: ((Root, 7), 4)
    time: ((Root, 9), 1)
    time: ((Root, 10), 3)
    time: ((Root, 10), 4)
    time: ((Root, 10), 5)
    time: ((Root, 10), 6)
    time: ((Root, 10), 7)
    time: ((Root, 10), 8)

As intended, we do all the work for one round before we proceed to the next
round. Within each round, we perform work by iteration, as we kinda need to do
one iteration before the next.

Actually, the _real_ reason we do iterations in order is that timely dataflow
sees that there is a back-edge in our dataflow graph, and that updates at
`(round, iter)` can result in updates at `(round, iter+1)`. Timely dataflow does
not give the go-ahead to differential dataflow operators until all of the work
of the previous iteration has finished. That is why things actually happen in
iteration order.

Notice that there is not a back edge from "previous rounds" to "subsequent
rounds". Timely dataflow can see that updates at `(round, iter)` cannot result
in updates at `(round+1, iter)`. What could the implications be ...

#### Way 2: Update all the things!

Let's let timely and differential off the leash. Instead of holding back on
advancing the inputs, lets just put all the data in right away (but still at the
correct rounds):

```rust
for round in 0 .. rounds {
    // sliding window, let's pretend ...
    graph.send((edges[edge_count + round], 1));
    graph.send((edges[round], -1));
    graph.advance_to(round + 1);
}

// run like crazy!
computation.step_while(|| probe.lt(&graph.time()));
```

This version of the code just dumps all the data in, and only once it is done
does it go and start running the computation. At this point, timely knows that
the input can't producing anything before `rounds`; what happens when
differential sees this information?

    time: ((Root, 0), 0)
    time: ((Root, 0), 1)
    time: ((Root, 0), 2)
    time: ((Root, 5), 2)
    time: ((Root, 9), 1)  <-- wtf?
    time: ((Root, 0), 3)
    time: ((Root, 5), 3)
    time: ((Root, 7), 3)
    time: ((Root, 10), 3)
    time: ((Root, 0), 4)
    time: ((Root, 2), 4)
    time: ((Root, 7), 4)
    time: ((Root, 10), 4)
    time: ((Root, 2), 5)
    time: ((Root, 10), 5)
    time: ((Root, 10), 6)
    time: ((Root, 10), 7)
    time: ((Root, 10), 8)

Chew on that for a bit.

Actually, I think this all makes a lot of sense if you ignore the `(9,1)` for
the moment. If you ignore that time, all of the other updates are done in
iteration order. Timely and differential agree that we can do the work for each
of the iteration `2`, `3`, `4`, and `5` at the same time, even before all work
at prior rounds have completed.

The `(9,1)` update is a bit of a mystery, but nothing about differential
dataflow's operator implementation guarantees that all work that can be
performed will be performed _immediately_. In particular, there are several
points where the operator learns it will need to do some more work, and enqueues
the work rather than testing whether the work can be done right away. The
apparent `(9,1)` disorder may just be a result of this. It's not an incorrect
disorder, just work we could have done before `(0,2)` and `(5,2)` if we wanted
to.

#### Way 3: A little bit of both

We could also do a bit of both: ingest some data, do some computation, ingest
some data, do some computation. This is a lot more like what we actually expect
in a streaming system. Taking all the timestamped input at once is more like a
temporal database (as I understand them), and taking the timestamped input only
one update at a time is like .. a bad streaming system I guess.

So let's do that, doing a few rounds (three) of computation after each update,
but not necessarily running until all updates for the round are complete. What
do we see:

    time: ((Root, 0), 0)
    time: ((Root, 0), 1)
    time: ((Root, 0), 2)
    time: ((Root, 0), 3)
    time: ((Root, 5), 2)
    time: ((Root, 0), 4)
    time: ((Root, 2), 4)
    time: ((Root, 5), 3)
    time: ((Root, 7), 3)
    time: ((Root, 2), 5)
    time: ((Root, 7), 4)
    time: ((Root, 9), 1)
    time: ((Root, 10), 3)
    time: ((Root, 10), 4)
    time: ((Root, 10), 5)
    time: ((Root, 10), 6)
    time: ((Root, 10), 7)
    time: ((Root, 10), 8)

This begins and ends pretty predictably, for obvious reasons (nothing to work on
at beginning / end other than the first / last update). But in the middle we see
some pretty neat stuff. I'm thinking specifically of

    ...
    time: ((Root, 2), 5)
    time: ((Root, 7), 4)
    time: ((Root, 9), 1)
    ...

Here we've got a neat little wave-front cutting through our `(round, iter)`
partial order. Each of these times are mutually incomparable (none can lead to
another), and they can all be processed concurrently.

### What needs to be different

If timely dataflow already lets us re-order the computation, and allows us to
process multi-element wavefronts concurrently, what is the problem?

Although timely gives operators enough information, there are several
implementation issues that emerge if we just let timely dataflow run free on
fine-grained timestamps.

1.  **Each timestamp has lots of overhead**

    We already mentioned that timely does coordination for each timestamp, and
    that is still true a few sections later. If we want to avoid bogging down
    the computation with control traffic, we'll need to think of a better way of
    talking about all the different timestamps.

2.  **Differential operators run first by time, then by key**

    Even though timely informs the operators that they can re-order compuation
    by iteration rather than by round, within an operator the implementations
    still operate in blocks of logical time, rather than processing all
    available times for each key. We'll want to fix this (for sanity), but it
    also opens the door to improved locality (one pass over keys per
    invocation).

These two problems have relatively tractable solutions, which I'll just spill
out there. Neither is properly implemented, but the first is in use in timely's
logging infrastructure, and the second has been typed into comment out code.
Pretty serious business.

Honestly, the first step seems totally simple and workable, and I expect no
issues. The second step will likely eventually work, but it risks discovering
some horrible algorithmic nightmares along the way. That being said, here we go:

#### Step 1: High-resolution streams

Right now update streams in differential take the form of timely dataflow
messages, where the data have the form

```rust
    (record, diff): (D, isize)
```

There is some record, and a count indicating by how much it has changed. Like
all timely dataflow messages, there is a time attached to the message, and we
treat that as the time for all updates in the message. A timely dataflow message
therefore looks something like (but is actually nothing like):

```rust
    (Time, Vec<(D, isize)>)
```

That is great if there are lots of updates with the same time, as they can get
bundled together. This doesn't work especially well if, in the limit, there is
just one update for each time. In addition to the control traffic, each update
gets sent out as a singleton message with lots of associated overhead.

So, a different way of doing things, a more painful way if you don't actually
need the flexibility, is to pack the times in as data as well, sending messages
like

```rust
    (Time, Vec<(D, Time, isize)>)
```

We have `Time` in there twice now, but the two uses serve different roles. The
first `Time` is timely dataflow's "capability". It tells timely dataflow, and
us, at which logical times downstream operators are allowed to send data by
virtue of holding on to this message. The second times tell us when changes
_actually_ occur, but these times don't need to be equal to that of the
capability; timely dataflow doesn't know about them.

It turns out that for things to make sense, all of the second times should be
greater or equal to that of the capability. If a change occurs, it may
precipitate changes at that or future times, and we really want a capability
that allows us to send messages reflecting those times. Correspondingly, we want
timely dataflow's promise that "no messages with a given capability will arrive"
to have meanining; the completion of a capability timestamp will imply the
completion of the corresponding data timestamps.

So that's the plan. Bundle up batches of `(D, Time, isize)` updates and send
them along with a capability that is less or equal to each of the times. Of
course we can't just mint a capability out of nowhere, so it will really be the
reverse: grab a capability and use it to send all the pending updates at times
greater than or equal to its time. Once we've sent everything we need to, throw
away the capability and let workers proceed to whatever bundles of times are
next.

If we ever end up needing to send an update in the future of no capability we
hold, we done screwed up.

#### Step 2: High-resolution operators

Operators currently receive timely dataflow messages of the first (time-free)
form above, and receive progress information about the capabilities on those
messages. We will need to rethink both of these, as well as the general
structure of the operator's logic.

Informally, a differential dataflow operator accepts input updates into a pile,
differentiated by timestamp. When it learns from its input that a timestamp in
its pile is finished, it picks up all the updates with that timestamp and
commits them. It then flips through all the keys in these committed updates, and
checks whether the operator logic applied to the input collection at this time
still produces the accumulated output at this time, and issues updates if not.

Actually it is a bit more complicated, but let's not worry about that here.

The rough structure up above is time-by-time, but there is nothing much that
prevents it from operating in terms of time _intervals_ rather than individual
times. You probably know what an interval is, right? Something like `[a, b)`
that says "`a` and stuff up to but not including `b`".

We are going to do this, but where `a` and `b` are
[antichains](https://en.wikipedia.org/wiki/Antichain).

An antichain is a collection of mutually incomparable elements from a partial
order, and in timely dataflow it acts a bit like a line cut across the partial
order (not actually; that would be a
[maximal antichain](https://en.wikipedia.org/wiki/Antichain#Height_and_width)).
We will speak of the interval `[a, b)` as those elements of the partial order
greater or equal to some element of `a`, but not greater or equal to any element
of `b`.

This may make more sense to think about an interval as those times that, from
the point of view of a differential dataflow operator, were not previously
complete (greater-or-equal to the prior input frontier) but are now complete
(not greater-or-equal to the current input frontier). As an operator executes,
the sequence of input frontiers it observes evolves, and each step defines an
interval of this form.

With that thought in mind, our plan is to have each operator first identify the
interval of newly completed times, say `[a,b)`, and then pull all updates with
times in this interval. I don't know a great datastructure for this, so the
working plan is that all `(D, Time, isize)` updates are just going to be in a
big list that we scan each time the frontier changes. Once we pull out updates
at newly completed times, we order them by key and process each key
independently.

There are more details for sure, but once we are willing to just re-scan piles
of updates in the name of performance, many doors are open to us.

#### Organization

I'm not sure I want to try and write operators that hybridize high-resolution
and low-resolution implementations. At the moment I'm more inclined to
specialize the `Collection` type, which wraps a stream of updates, into two
types:

1. `LoResCollection`, which has relatively few distinct times, and bundles data
   without additional logical times as data.

2. `HiResCollection`, which has relatively many distinct times, and bundles
   logical times in with the data.

These two types can now have separate implementations of `group` and `join` and
such. This does raise the question of what happens with `join` where the inputs
are different granularities, and I don't know other than it is pretty easy to
promote a `LoResCollection` to a `HiResCollection` just by sticking the same
time in the payload. We could go the other way, but at an unboundedly horrible
cost, so let's not.

Actually, the current `Trace` interface masks details about high-resolution vs
low-resolution, and operators like `join` just take pre-arranged traces rather
than weirdly typed `Collection` structs. It might be surprisingly non-horrible
to meld the two representations together, for example supporting a frequently
changing graph and an infrequently changing queries against it. I'm not sure how
we would choose which output type to produce, though (the higher-resolution, of
course, but how to determine this without specialization).

Related, we will evenutally want to meld high- and low-resolution trace
representations. Quickly changing edge sets call for a high-resolution
representation, but once the times have passed and we want to coalesce the
updates, the resulting updates change only with iterations and not rounds, and
admit a low-resolution representation. The low-resolution implementations can be
much more efficient than the high-resolution ones, because they avoid some
massive redundancy in re-transcribing the times with every update.

All in all, I think there are some great things to try out here, many likely
pitfalls, but some fairly cool potential. I'm optimistic that we will soon get
to a system that processes updates with high-resolution _and_ high-throughput,
for as long as you run the system.

It will probably be slower on some batch graph compute, but are people really
still working on that stuff?

### Addendum: A Prototype (March 5, 2017)

I have a prototype up and running. It seems to produce the correct output, in
the sense that it produces exactly the same outputs whether you run it with one
update at a time, or one million updates at a time. Also, the output isn't
empty; I thought to check that.

First up, let's look at some measurements from the previous pile of code. This
previous pile takes batches of records which all have the same time. This means
that if you want each update to have its own timestamp, you get lots of small
batches. If you put multiple updates together in a batch, they all have the same
timestamp and their effects can't be distinguished.

Using this implementation, let's get some baseline measurements. We are going to
look at the breadth-first search computation (how many nodes are at each
distance from the root) doing one million updates to two random graphs, one with
1,000 nodes and 2,000 edges, and one with 1,000,000 nodes and 10,000,000 edges.
We will do the one million updates a few different ways, batching the updates in
batches of sizes from one up to one million (e.g. `10 x 100000` means batches of
size 10, done 100,000 times). All updates in a batch have the same timestamp.

|  experiment | 1k / 2k | 1m / 10m |
| ----------: | ------: | -------: |
| 1 x 1000000 |    142s |     100s |
| 10 x 100000 |     73s |      64s |
| 100 x 10000 |     27s |      51s |
| 1000 x 1000 |      5s |      48s |
| 10000 x 100 |       - |      34s |
| 100000 x 10 |       - |      21s |
| 1000000 x 1 |       - |      12s |

We don't have measurements for 10,000 and larger batch sizes for the small
graph, because with only 2,000 edges and the same timestamp for all the updates
in a batch, most of the changes would just cancel. I should say, although it is
trivial for the `1k / 2k` graph, the `1m / 10m` graph takes about eight seconds
to load its ten million edges, and these numbers include that.

Notice the massive discrepancy between single-element batches (142s and 100s)
and the larger batches (5s and 12s). This is a pretty substantial throughput
difference. We would love to get that throughput, or something close to it,
while keeping the resolution of single-element updates.

#### The prototype

There is some prototype code! Yay! It is _pretty weird_ code, not like much I've
written before. I'm quite certain there are inefficiencies in it, so the
absolute numbers are just an indication that we are moving in the right
direction. These are the same experiments as above, except here _every update
has a distinct timestamp_. We are producing the output that corresponds to the
`1 x 1000000` row from above, but without shattering all the updates into
different batches.

|  experiment | 1k / 2k | 1m / 10m |
| ----------: | ------: | -------: |
| 1 x 1000000 |       - |        - |
| 10 x 100000 |    237s |      94s |
| 100 x 10000 |    173s |      75s |
| 1000 x 1000 |    148s |      57s |
| 10000 x 100 |    623s |      43s |
| 100000 x 10 |       - |      31s |
| 1000000 x 1 |       - |      25s |

There are several things different about this chart.

1. First up, you may notice we didn't do a batch size 1 row. There are some
   things we do assuming there will be lots of work, and when there isn't lots
   of work we do it anyhow. The whole point of this research is to move to
   larger batches. That being said, this will probably be fixed. These same
   issues end up hurting the small graph more than the large graph; the small
   graph is sparser, and updates cause longer cascades of small updates.

2. We have a `10000 x 100` entry for the smaller graph! It makes sense to run
   the experiment now, because each update with a different time doesn't result
   in cancelation. Unfortunately, it is terrible. The reason here seems to be
   the same reason we had to do that
   [compaction](https://github.com/frankmcsherry/blog/blob/master/posts/2017-02-11.md)
   stuff: with so many updates, each of the 1,000 keys gets a sizeable history,
   and within a batch we are trying to process all of it without compacting it.
   The makes us go quadratic in the number of updates per key per batch. The
   good news is that we should be to do compaction on our own. The bad news is
   that I have to code that up.

3. The `1m / 10m` column doesn't look so bad, does it? The times are worse than
   before, for sure, but not by all that much. They are roughly "one batch size
   worse", I think. And the results tell us the exact consequences of each
   individual update, corresponding to the `1 x 1000000` row up above. I think
   these could also get a bit better, because there are some fairly feeble
   moments in the code.

Let's take the `1m / 10m` experiment and crank up the number of workers. Note:
we are still producing the high-resolution outputs.

|  experiment | 1 worker | 2 workers |
| ----------: | -------: | --------: |
| 1 x 1000000 |        - |         - |
| 10 x 100000 |      94s |       82s |
| 100 x 10000 |      75s |       58s |
| 1000 x 1000 |      57s |       39s |
| 10000 x 100 |      43s |       28s |
| 100000 x 10 |      31s |       20s |
| 1000000 x 1 |      25s |       15s |

Here, one worker takes 8s before it starts processing updates, and two workers
take 5s before they start processing updates. These numbers include those two
(and look a bit better if you mentally subtract that out).

This is pretty good news, I think. For small batches the second worker doesn't
help much, which is what we should expect; the high-resolution changes don't
improve the performance of small batches, they make larger batches produce the
same output. The larger batches do get a decent benefit from additional workers;
the scaling isn't 2x, and it probably shouldn't be (we have to do data exchange,
and flail around with some buffers).

This looks pretty promising to me. We can get the output that used to take us
92s (100s - 8s) now in just 10s to 15s. Or, maybe 23s if we want sub-second
response time. See, we need to take the total time and divide by the number of
batches to get the average response time, and we only get 1m updates / 10s
throughput if we want to wait for 10s. In fact, if that is our strategy there
are going to be some updates that take 20s before we see their implications.
We'd really like to draw down the numbers for the medium batch sizes.

There are for sure things to improve in the code, and I hope and expect these
numbers to come down. I'm also worried about (and planning on fixing) the
numbers for the smaller graph, which I'd very much like to work hitch-free. In
particular, I'd love to have an "idiot-proof" implementation that just works for
any reasonable problem, without careful caveats about settings of batch sizes
and the like. Watch this space!

### Addendum: Small message optimization (March 7, 2017)

One of the "things we do assuming there will be lots of work", alluded to above
as a reason we might have poor performance on small batch sizes, is radix sort.
As I've written it, there are 256 numbers to go and check each time you radix
shuffle on a byte, because there are that many different bytes each record might
have produced. You do this for each byte position of (in this case) an
eight-byte key.

If you just have 10 elements to sort, just call `.sort()`.

I've done that now. The times have improved, generally. Old times are in
parentheses:

|  experiment |     1k / 2k |  1m / 10m | 1m / 10m -w2 |
| ----------: | ----------: | --------: | -----------: |
| 1 x 1000000 |           - |         - |            - |
| 10 x 100000 | 157s (237s) | 73s (94s) |    64s (82s) |
| 100 x 10000 |  79s (173s) | 58s (75s) |    46s (58s) |
| 1000 x 1000 |      (148s) | 53s (57s) |    36s (39s) |
| 10000 x 100 |      (623s) | 41s (43s) |    28s (28s) |
| 100000 x 10 |           - |     (31s) |        (20s) |
| 1000000 x 1 |           - |     (25s) |        (15s) |

Some measurements weren't re-taken, under the premise that they shouldn't be
improved (and I'm getting dodgy numbers the more my laptop runs and heats up).

The small instance still suffers from the second issue above: that the
implementation's behavior is quadratic in the number of times per key in each
batch. For the `10000 x 100` experiment, several keys have more than 100 times,
resulting in 100x overhead that could be substantially reduced. I have a partial
solution for that, but it is vexxingly hard to do some things with general
partial orders that are so very, very simple for integers that just increase.

Even in the larger graph, we can see large numbers of times for each key. I had
`group` capture a histogram of the number of distinct times each key processes
in each batch, and for the `1000000 x 1` experiment (the largest batch size,
admittedly, but also one we thought was getting decent performance), we get
distributions of distinct times that look like:

    counts[1]:	56707
    counts[2]:	106391
    counts[3]:	144178
    counts[4]:	158547
    counts[5]:	149205
    counts[6]:	123057
    counts[7]:	91704
    counts[8]:	62347
    counts[9]:	39843
    counts[10]:	23667
    counts[11]:	13367
    counts[12]:	7006
    counts[13]:	3644
    counts[14]:	1823
    counts[15]:	857
    counts[16]:	347
    counts[17]:	173
    counts[18]:	67
    counts[19]:	33
    counts[20]:	19
    counts[21]:	6
    counts[22]:	3
    counts[23]:	2
    counts[24]:	1

Most of the keys are doing some amount of redundant work here. Each time
currently rescans the input updates and re-accumulates collections, whereas most
of this work can be done just once and then updated as we move through times.
That's not the whole story though, which will have to wait for the next
addendum.

### Addendum: Many distinct times optimizations (March 24, 2017)

I have a candidate for `group` that works relatively well even with large
numbers of distinct times for each key. The details will need to wait for a
longer blog post, but they roughly amount to looking for totally ordered runs in
the times we work with, and (future work) re-arranging the times to have longer
runs. The result is an implementation that is linear (plus sorting) in the
number of updates, multiplied by the number of times that are not `gt` their
immediate predecessor.

This works great for total orders, and is a start for partial orders. I still
have some more to do with respect to re-ordering times to cut down on this
number, but already there are some improvements in running times. Here are
updated numbers with old execution times in parentheses (note: other
optimizations have happened along the way, so this isn't just about a new
algorithm).

|  experiment |     1k / 2k |  1m / 10m | 1m / 10m -w2 |
| ----------: | ----------: | --------: | -----------: |
| 1 x 1000000 |           - |         - |            - |
| 10 x 100000 | 117s (157s) | 82s (73s) |    68s (64s) |
| 100 x 10000 |   75s (79s) | 65s (58s) |    46s (46s) |
| 1000 x 1000 |  87s (148s) | 58s (53s) |    40s (36s) |
| 10000 x 100 |  70s (623s) | 47s (41s) |    33s (28s) |
| 100000 x 10 |        131s | 34s (31s) |    21s (20s) |
| 1000000 x 1 |        385s | 26s (25s) |    19s (15s) |

As you can see, several numbers for the smaller graph got much better, and at
the same time the numbers for the larger graph got a bit worse. This makes
sense, as the code is certainly more sophisticated than before, and if the
problem didn't exist (e.g. the larger graph) we are just paying a cost. That
being said, I bet we can recover these losses and more when we actually try and
optimize the implementations; if nothing else, we can just drop in to the
simpler implementation for small numbers of times and save the complex one for
large number of times.

Also in the measurements, the times for the small graph are not strictly
improving as we increase the batch size. This is probably a result of not really
nailing the smallest number of totally ordered chains yet, though I can't really
confirm that yet. There are some other reasons that arbitrarily large batches
aren't perfect for iterative algorithms (in each iteration we must at least pick
up previous updates, making each iteration take time linear in the sum of batch
sizes of prior iterations, rather than just their own size).

### Addendum: Fixing some deranged allocation (March 26, 2017)

You might notice in the numbers above a disappointing spike up to `87s` for the
small graph in the `1000 x 1000` configuration. It turns out this is because one
thousand updates, which turns into two thousand changes (one edge in, one edge
out), is just over the threshold we used for "should we radix sort or not?".
This means that for these settings, we end up allocating some 256 buffers and
working with them a fair bit. And then we drop them on the floor so that we can
re-allocate them the next time around. Not very bright.

In fact, it was much sillier than that. The sorting happens as part of
separating an undifferentiated pile of updates into "sealed" updates, those
whose times have passed and we are not ready to finalize, and updates that stay
in the pile. We were doing the "should we radix sort" based on the
undifferentiated number, rather than the number we would eventually have to sort
(those of finished times). Because of how partially ordered times work, and that
timely dataflow can only carry one capability at a time, we end up slicing these
batches even more finely when the frontier advances, so that we have several
small sealed sets. Each of them have the bad radix sorting allocate-and-drop
behavior.

So that should be fixed. I even pushed a new version of `timely_sort` (some
radix sorting code) that does less allocation. I'm not quite using it yet, but
even with the local fixes, numbers look better:

|  experiment |     1k / 2k |  1m / 10m | 1m / 10m -w2 |
| ----------: | ----------: | --------: | -----------: |
| 1 x 1000000 |           - |         - |            - |
| 10 x 100000 |      (117s) |     (82s) |        (68s) |
| 100 x 10000 |       (75s) |     (65s) |        (46s) |
| 1000 x 1000 |   63s (87s) | 54s (58s) |    36s (40s) |
| 10000 x 100 |   61s (70s) | 43s (47s) |    28s (33s) |
| 100000 x 10 | 127s (131s) | 31s (34s) |    20s (21s) |
| 1000000 x 1 |      (385s) | 23s (26s) |    16s (19s) |

The configurations with batches smaller than one thousand really shouldn't see
much change, and the much larger batches shouldn't have _much_ change (some
small batches emerge in the computation for larger batches). There is some
serious improvement for the small graph, and decent improvement for the large
graph. We are mostly regaining ground on the larger graph, having taken a hit
from the complexity of the new and complicated "linear-ish" algorithm.

What these numbers should tell you, though, is that all this code is new enough
that we are getting 10% improvements just by looking at it and removing the
stupid. I'm planning on doing a bit more of that next. For example, each time we
radix sort one thousand elements, we compute the hash of each eight times. Why
would we do that?

One appealing aspect of Rust (over managed languages) is that there is no reason
we shouldn't be able to write the code that does what we think it should do, and
in this case we kinda think we should be able to sort some updates by key, zip
them along stashed state, and compute and ship output differences. Any thing
that takes time is either because (i) we aren't actually doing that yet, or (ii)
we are doing it badly. Each of these should be fixable.

One problem is that I don't actually know how fast we _should_ be able to
compute one million related bfs computations. Should we hope to get the `1k/2k`
number down to one second? Why not? That seems like a good goal to aim for. Or
at least, we should understand what are the large number of fundamental
computations that prevent us from that goal.

### Addendum: Quadratic behavior in `join` (March 31, 2017)

I found the source of the bad behavior for the small graph!

When shifting from "each batch contains one time" to "batches may contain
multiple times" I was pleased to find that the `join` logic still passed its
tests and didn't seem to need any fixing. Wow was that wrong.

First, it turns out that `join` as written wasn't even correct. It passed all
the tests because `bfs` (which I used as the "integration" test) never has both
of its join inputs vary at the same time. Sure the `edges` change and the
`dists` change, but it is always either one (new round of edge data) or the
other (new iteration). So I fixed that (the bug, not the test).

More interestingly, I think, it became patently clear that the implementation
would quite happily go quadratic even on joins where there was _no_ output. Let
me explain how join used to work:

When joining two sources of data, we get sequences of batches of updates, each
of which looks kind of like a `Vec<(K, V, T, R)>` (where you should think of `R`
as `isize`). For each batch we receive, we want to join it with all batches
received so far on the _other_ input. This is a fairly traditional streaming
equijoin. So we join one `batch` with the `trace` of all history for the other
input (probably compacted a bit; that isn't the issue) on the other side:

```rust
for key in batch.keys() {
	for &(val1, time1, diff1) in &batch[key] {
		for &(val2, time2, diff2) in &trace[key] {
			output.ship(((val1, val2), time1.join(&time2), diff1 * diff2));
		}
	}
}
```

Amazingly, due to bi-lineary of `join` and the way differential dataflow
difference work, this is actually correct. Even more clearly, this will do an
amount of work proportional to the product of the sizes of `batch` and `trace`.
That makes some sense, because we probably expect to see an output for each pair
of values in `batch` and `trace`, right?

WRONG!

This is where I started to think that maybe I should read about temporal
databases or something, rather than "discovering" all this stuff myself. Over
the course of the history of `batch` and `trace`, the collections may never grow
to be all that big. In fact, they could totally alternate empty / non-empty out
of sync, in which case there would be no matches. All we would need to do to see
this would be to play each history in order, which takes time linear in the
inputs.

So I wrote a better inner loop for join when the histories are big and scary
(and fall back to the default implementation when they are not). The idea is
roughly to walk through the histories in order, maintaining each collection's
updates accumulated with respect to the remaining frontier of times for the
other collection (for total orders, read this as: "updated in place").

Returning to our trusty `bfs` experiment, we get new numbers that look like (old
numbers in parentheses):

|  experiment |    1k / 2k |  1m / 10m | 1m / 10m -w2 |
| ----------: | ---------: | --------: | -----------: |
| 1 x 1000000 |          - |         - |            - |
| 10 x 100000 |     (117s) |     (82s) |        (68s) |
| 100 x 10000 |      (75s) |     (65s) |        (46s) |
| 1000 x 1000 |  62s (63s) | 56s (54s) |    38s (36s) |
| 10000 x 100 |  59s (61s) | 47s (43s) |    32s (28s) |
| 100000 x 10 | 69s (127s) | 36s (31s) |    23s (20s) |
| 1000000 x 1 | 73s (385s) | 32s (23s) |    21s (16s) |

This is, much like a post or two back, a serious improvement for the small
graph, and a non-trivial regression for the larger graph.

I'm not entirely sure what is wrong with the larger graph, in that the join
implementation is largely the same for uncomplicated histories, except that it
must first extract the history to check if it is complicated; the old
implementation didn't have to copy data out from `batch` and `trace` to look at
it, which is perhaps the issue? I feel like we can eventually work around that,
especially given that batch exfiltration of data should be faster than the
careful navigation we were (and still are, unfortunately) doing to read the
data.

Looking at a profile, the large graph `1000000 x 1` experiment spends only 6% of
its time in `join` at all, so the serious regression seems unlikely to live
there. I don't think I've changed `group` in the meantime, so I'm not exactly
sure what is screwed up; perhaps I tweaked the measurement program
inappropriately, or perhaps I caught a dodgy measurement the previous time
around (when there was, in fairness, a buggy join implementation).

For the small graph, the bulk of the time is now spent in `group`, in some
operations that may still have some defective performance (sorting mostly, it
seems; technically super-linear). It would be great to get performance to
improve with increasing batch size before starting to optimize the
implementations.

### Addendum: Simplifying "interesting times" (March 31, 2017)

One complicated bit of logic in `group` determines the logical times at which we
may need to re-evaluate user logic. It is not so much complicated, as much as I
made it complicated. The logic is meant to take two sets of times, `old` and
`new` let's say, and determine the times that are the lattice join of a subset
of `old` and a non-empty subset of `new`.

For example, here is the reference implementation that I wrote (here `edits` is
the old set and `times` is the new set):

```rust
// REFERENCE IMPLEMENTATION (LESS CLEVER)
let times_len = times.len();
for position in 0 .. times_len {
    for &(_, ref time, _) in edits {
        if !time.le(&times[position]) {
            let join = time.join(&times[position]);
            times.push(join);
        }
    }
}

let mut position = 0;
while position < times.len() {
    for index in 0 .. position {
        if !times[index].le(&times[position]) {
            let join = times[index].join(&times[position]);
            times.push(join);
        }
    }
    position += 1;
    times[position..].sort();
    times.dedup();
}
```

It does a bunch of work, much more than the possibly linear-time implementation
I worked hard on. Of course, it is so much simpler (by about 80 lines, and many
loops), and we should probably just use it when we don't have lots of edits.
Because often we don't have lots of edits.

|  experiment |   1k / 2k |  1m / 10m | 1m / 10m -w2 |
| ----------: | --------: | --------: | -----------: |
| 1 x 1000000 |         - |         - |            - |
| 10 x 100000 |    (117s) |     (82s) |        (68s) |
| 100 x 10000 |     (75s) |     (65s) |        (46s) |
| 1000 x 1000 | 58s (62s) | 55s (56s) |    38s (38s) |
| 10000 x 100 | 56s (59s) | 46s (47s) |    30s (32s) |
| 100000 x 10 | 67s (69s) | 35s (36s) |    23s (23s) |
| 1000000 x 1 | 74s (73s) | 31s (32s) |    23s (21s) |

These are pretty minor effects, with some light improvement in the smaller batch
sizes where we expect less complicated histories. I was initially really excited
about this because I conflated the improvements with the next optimization, but
once I broke them apart this was not the better part. Sorry!

### Addendum: Avoiding expensive hashing (March 31, 2017)

What actually makes a difference is ripping out a fair amount of redundant
hashing. Our default storage uses hash tables to index data by key, which is
really helpful when we have relatively few keys in each batch. At the same time,
our default implementation just calls each types associated hash function when
it needs a hash, which can be quite a lot.

In particular, when we first arrange data into batches we sort it (by key, then
value, then time), and while this is primarily a radix sort using the hash, we
need to finish it with a standard Rust sort to deal with possible hash
collisions and to get values and times ordered too. If we have lots of data, and
especially if we have lots of equivalent keys, this ends up calling the hash
function on the key quite a lot.

There is a small change we can make to cache the hash value; doing that doesn't
seem to help all that much; it probably makes sorting faster but then costs
later on when we need to move around keys and hash values together. This is
worth looking into more, because if you show up with long `String` keys you
aren't going to want lots of hash re-evaluation.

A simple change, for the purposes of graphs, is to use random node identifiers
and have each identifier be its own hash value. This works out great, and we get
generally improved performance:

|  experiment |   1k / 2k |  1m / 10m | 1m / 10m -w2 |
| ----------: | --------: | --------: | -----------: |
| 1 x 1000000 |         - |         - |            - |
| 10 x 100000 |    (117s) |     (82s) |        (68s) |
| 100 x 10000 |     (75s) |     (65s) |        (46s) |
| 1000 x 1000 | 51s (58s) | 51s (55s) |    31s (38s) |
| 10000 x 100 | 51s (56s) | 38s (46s) |    25s (30s) |
| 100000 x 10 | 60s (67s) | 28s (35s) |    19s (23s) |
| 1000000 x 1 | 66s (74s) | 24s (31s) |    17s (23s) |

This recovers a fair chunk of time we lost previously, and this difference could
actually be the source of the apparent regression (perhaps I was using this
version before; I certainly have in the past).

One question this raises is whether we really need hash tables as the index
structure. They are helpful for sparse access, but if our plan is to push hard
on throughput, perhaps simple ordered lists are good enough. They are much
simpler to construct, and very cheap to merge. They would likely kill the
numbers for small batch sizes, effectively raising the "minimum latency" you
would experience for small loads. This will also be fun to check out, though.

Plus we are actually going to put real indices in place at some point, which
should make the distinction less important.

We still have an up-tick for increasing batch sizes in the small graph, and I
still want to sort that out. Removing all this hashing is one way of getting rid
of the noise that is leaving the source of the problem a mystery.

### Addendum: Re-engineering `group` (April 2, 2017)

I did a bit of a re-write of the core `group` logic. Not much has changed
algorithmically, but certain parts were tidied up enough that we spend less time
futzing around with messy piles of data.

For example, previously the operator accepted batches of keyed input data, and
for each key flipped through all times to create a list of `(key, time)` pairs
we should look into. That's great, but we didn't really need to do that; we can
just wait until we start to work on the key, and put together the list of times
for that key. This required a bit of sanity checking about "exactly what times
are we planning on working on" that was enabled by the simplified code
structure.

We also bite off a larger chunk of the graph to work on, doing only one sweep
through the keys where we may previously have done several, feeding the output
into different batches as appropriate (when we have multiple incomparable
capabilities).

|  experiment |   1k / 2k |  1m / 10m | 1m / 10m -w2 |
| ----------: | --------: | --------: | -----------: |
| 1 x 1000000 |         - |         - |            - |
| 10 x 100000 |    (117s) |     (82s) |        (68s) |
| 100 x 10000 |     (75s) |     (65s) |        (46s) |
| 1000 x 1000 | 45s (51s) | 57s (51s) |    44s (31s) |
| 10000 x 100 | 39s (51s) | 43s (38s) |    30s (25s) |
| 100000 x 10 | 48s (60s) | 29s (28s) |    19s (19s) |
| 1000000 x 1 | 55s (66s) | 20s (24s) |    12s (17s) |

Some interesting things happen here. The small graph performance improves a fair
bit, the very large batch performance improves quite a bit (more on this), and
the small batch large graph performance takes a bit of a hit. I'm not exactly
sure what the deal is here, except that we are doing more work in larger batches
now, and this provides both opportunities to do things well and to do things
badly.

I want to call out the large graph, multiple worker numbers. There is a pretty
serious improvement there, which is even more impressive when you learn that the
first 4.5 second are just prepping the computation (loading the graph and doing
the initial bfs computation). So what we are actually seeing appears to by 12s
of compute down to 8s of compute. I just need to do that a few more times. Also,
make sure to run integration test to see that we are producing the correct
output (ed: apparently).

### Addendum: Less interesting times (April 7, 2017)

I made what I think of as a pretty substantial change to the way `group` works.
Let me recap, both because it gets us on the same page, and because I need the
practice.

The `group` operator works on a bunch of keys in parallel, and for our purposes
we are just going to talk about what it does for each key individually (it maps
this behavior across all keys).

The `group` operator repeatedly gets presented with batches of updates each of
which corresponds to an _interval_ of partially ordered time: `[lower, upper)`,
where `lower` and `upper` are both antichains (sets whose elements are mutually
incomparable) and the interval includes those times greater or equal to an
element of `lower` but not greater or equal to any element of `upper`.

When presented with an interval of updates, the `group` operator is now in a
position to determine the corresponding interval of updates to its output. All
of the inputs updates at times not after `upper` have been locked in, and this
means that mathematically that all of the output updates at times not after
`upper` are also locked in, we just haven't computed them yet. So the `group`
operator needs to determine the output updates at times in the interval
`[lower, upper)`.

The previous implementation did this by tracking all of the times at which the
output might change, and each time around seeing which of these times are in the
interval `[lower, upper)` and working on those times. This was intended to be
very precise, but it has some serious overhead and, counter-intuitively, can end
up less precise that simpler methods.

The current implementation (this is all a work in progress) just takes as input
`lower` and `upper`, and starts looking for times that land in this interval. A
time is plausibly interesting, in that it could possibly have a non-zero output
update, if it is the join of sets of times found in input or output updates. As
we are (currently) planning on walking through all updates anyhow (to "simulate"
the history of the values for the key), we have the opportunity to start forming
these sets of joined things and seeing which land in our target interval.

Although we might consider lots of times, each time will either be (i) in the
`[lower, upper)` interval, in which case we want to reconsider it, or (ii) at
`upper` or beyond, in which case we should defer it for future processing. We
can also skip any times in the future of defered times, because we'll just
re-discover them when we get to them in the future, right?

Or will we?

This is meant to be the "good news" of this approach: if in the future it turns
out that the updates that prompted some possibly interesting time vanish,
perhaps because they cancel when seen from this point in the future, then great!
Although we thought it might be worth looking in to what the input and output
look like at that time, if by the time we get to the interval containing the
time the updates just aren't there any more, no work for us to do!

Let's look at an example: Imagine we are supplying one thousand rounds of input
to an iterative computation, so timestamps look like `(round, iteration)`. We
might start with updates that look like

    ("hello", (17, 0), +1)
    ("world", (23, 0), +1)

Meaning that `"hello"` shows up in the 17th round of input and `"world"` shows
up in the 23rd round of input. Perhaps over the course of the iterative
computation, the `"world"` record evolves a bit and eventually goes away

    ("world", (23, 3), -1)

Of course, `"hello"` can evolve too, and perhaps in a later iteration it prompts
something exciting:

    ("wombat", (17, 5), +1)

This is very exciting, because wombats are magical animals. Now, based on our
tradition reasoning, in addition to our general excitement about wombats we may
also come to the conclusion that the time `(23, 5)` is pretty interesting. Some
stuff happens at `(_, 5)`, and some stuff happens at `(23, _)`, so stuff
probably happens at `(23, 5)` that we should check out.

As it turns out, nothing happens at `(23, 5)`, because by the time we've gotten
to iteration five, the `"world"` updates have canceled with each other. The
input collection is identical to the collection at `(23, 4)` and at `(22, 5)`
and even at `(22, 4)`, which pretty much means that it doesn't experience change
and so its output doesn't change either.

Our prior implementations, each of which tracked all possibly interesting times
explicitly, would miss this opportunity because they flagged the times `(17,3)`
and `(19,3)` as interesting, and lost track of the fact that their reasons for
being interesting cancel each other out. When we arrive at `(23, 0)` we would be
warned about the excitement associated with `(19, 3)` and

So that's all a very nice hypothetical optimization, but what does it do for our
`bfs` computation?

|  experiment |   1k / 2k |  1m / 10m | 1m / 10m -w2 |
| ----------: | --------: | --------: | -----------: |
| 1 x 1000000 |         - |         - |            - |
| 10 x 100000 |    (117s) |     (82s) |        (68s) |
| 100 x 10000 |     (75s) |     (65s) |        (46s) |
| 1000 x 1000 | 40s (45s) | 59s (57s) |    45s (44s) |
| 10000 x 100 | 39s (39s) | 45s (43s) |    31s (30s) |
| 100000 x 10 | 49s (48s) | 30s (29s) |    20s (19s) |
| 1000000 x 1 | 55s (56s) | 18s (20s) |    11s (12s) |

Not a great deal. There is a little bit of movement, but I think most of it is
attributable to noise.

This is sort of good news, because we haven't actually put the optimization of
ignoring canceling times into place yet, we are just seeing how well we do when
we have to rediscover times in each `[lower, upper)` interval rather than having
them listed for us. We removed a fair amount of "time management" code, at the
possible cost of re-evaluating the user logic at more times than strictly
necessary. Though, practically, I'm not sure we actually do any more evaluation
this way, as we were fairly conservative about which times we would consider
previously (in that we considered quite a lot).

|  experiment |   1k / 2k |  1m / 10m | 1m / 10m -w2 |
| ----------: | --------: | --------: | -----------: |
| 1 x 1000000 |         - |         - |            - |
| 10 x 100000 |    (117s) |     (82s) |        (68s) |
| 100 x 10000 |     (75s) |     (65s) |        (46s) |
| 1000 x 1000 | 40s (40s) | 59s (57s) |    42s (45s) |
| 10000 x 100 | 36s (39s) | 44s (45s) |    30s (30s) |
| 100000 x 10 | 46s (49s) | 30s (30s) |    20s (20s) |
| 1000000 x 1 | 56s (55s) | 18s (18s) |    10s (11s) |
