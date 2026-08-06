# Step 02 — The Object Model

> Goal: understand the three-part anatomy of every scene object. Everything in Grafana Scenes
> is built on this — panels, layouts, variables, query runners, your own custom objects.

## The three parts

Every scene object is made of exactly three things:

```
1. A State interface   — what data the object holds (extends SceneObjectState)
2. A Model class       — the object itself (extends SceneObjectBase<YourState>)
3. A React component   — how it renders (attached as a static property: static Component = ...)
```

Open `src/pages/Home/CustomSceneObject.tsx`. It is the minimal example of all three:

```ts
// 1. State
interface CustomSceneObjectState extends SceneObjectState {
  counter: number;
}

// 2. Model
export class CustomSceneObject extends SceneObjectBase<CustomSceneObjectState> {
  static Component = CustomSceneObjectRenderer;   // ← wires in the renderer

  onValueChange = (value: number) => {
    this.setState({ counter: value });             // ← mutate state
  };
}

// 3. Component
function CustomSceneObjectRenderer({ model }: SceneComponentProps<CustomSceneObject>) {
  const state = model.useState();                 // ← subscribe to state in React

  return (
    <Input
      defaultValue={state.counter}
      onBlur={(evt) => model.onValueChange(parseInt(evt.currentTarget.value, 10))}
    />
  );
}
```

## Key methods

### `setState(partial)`

Merges a partial state update, exactly like React's `setState`. Calling it triggers re-renders
in any component subscribed via `model.useState()`, and notifies any `subscribeToState` listeners.

```ts
this.setState({ counter: 42 });
```

### `model.useState()` — in React

A hook. Returns the current state and re-renders the component whenever state changes.

```ts
const state = model.useState();
// state.counter is always fresh
```

### `subscribeToState(callback)` — outside React

Used when one object needs to react to another object's state changes without being a React
component. Returns an `{ unsubscribe }` handle.

```ts
const sub = customObject.subscribeToState((newState) => {
  queryRunner.setState({ queries: [{ ...queryRunner.state.queries[0], seriesCount: newState.counter }] });
});

// later, to clean up:
sub.unsubscribe();
```

See this in action in `homeScene.ts` inside the `queryRunner.addActivationHandler` block — when
the counter changes, the query runner re-runs with a different `seriesCount`.

## Activation handlers

Objects are "activated" when they are mounted into the React tree and "deactivated" when unmounted.
`addActivationHandler` lets you run setup code on mount and return a cleanup function for unmount:

```ts
queryRunner.addActivationHandler(() => {
  const sub = customObject.subscribeToState(/* ... */);

  return () => sub.unsubscribe();   // ← cleanup on deactivation
});
```

This is the Scenes equivalent of `useEffect(() => { ... return cleanup }, [])`.

## The state is plain data

`this.state` is always accessible as a plain object — no getter needed:

```ts
queryRunner.state.queries[0].seriesCount   // read directly
```

Writes must always go through `setState()` — never mutate `state` directly.

## Exercise: add a `label` field to CustomSceneObject

1. Add `label: string` to `CustomSceneObjectState`
2. Render it above the `<Input>` in `CustomSceneObjectRenderer`
3. Instantiate it with `label: 'Series count'` in `homeScene.ts` (where `new CustomSceneObject` is called)
4. Run `npm run dev` and confirm the label appears in Grafana at http://localhost:3000

After the exercise, open `src/pages/HelloWorld/helloWorldScene.ts`. It uses `EmbeddedScene`,
`SceneFlexLayout`, `SceneFlexItem`, and `PanelBuilders` — the primitives in Step 03.

## What `SceneObjectState` adds

When you extend `SceneObjectState`, your state automatically gets these fields for free:

```ts
key?: string         // stable unique ID, auto-generated if not provided
$timeRange?          // inherited time range
$data?               // inherited data/query runner
$variables?          // inherited variable set
$behaviors?          // list of behavior objects
```

The `$`-prefixed fields are how Grafana Scenes propagates context down the tree without prop
drilling. A `VizPanel` deeper in the tree will automatically find the nearest `$timeRange` by
walking up to its ancestors. You never pass these explicitly between children.

## Analogy for Go/Python developers

Think of `SceneObjectBase` as a generic struct with a built-in observer pattern:

```go
// Go mental model (not real code)
type SceneObject[S any] struct {
    state     S
    listeners []func(S)
}

func (o *SceneObject[S]) SetState(partial S) {
    merge(&o.state, partial)
    for _, l := range o.listeners { l(o.state) }
}

func (o *SceneObject[S]) SubscribeToState(fn func(S)) Subscription {
    o.listeners = append(o.listeners, fn)
    return Subscription{Unsubscribe: func() { /* remove fn */ }}
}
```

The React component is just the "view" layer for that struct — it subscribes via `useState()`
and re-renders when the struct notifies it.

**Next:** [Step 03 — First Scene](../03-first-scene/README.md)
