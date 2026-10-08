# Ubuntu button fixture

The button example has a headless semantic projection in its portable fixture.
It publishes a window node and, while the button fits, a child button node
whose continuity key, label, logical bounds, enabled/loading/focused state and
`Invoke` action come from the existing `Button` model. The fixture validates an
`Invoke` request synchronously before routing the accepted effect to its
app-owned activation counter.

`ActionIntent` is a repeatable validation receipt, not a one-shot token and not
an action executor. This fixture deliberately does not deduplicate repeated
requests; application-specific idempotency belongs in the owner’s action path.
Reset clears the semantic model before the fixture recreates button key `42`,
so the replacement receives a fresh owner-scoped node generation. Removing and
restoring the button likewise makes an earlier node ID stale.

This is portable semantic-model dogfood only. It does not implement or claim a
native AT-SPI, D-Bus, UIA or AX bridge, and it is not a GUI or operating-system
accessibility acceptance result.

The stack is pinned to these reviewed public snapshots:

- GPUI main: `87d3e46ff35429ad747595f312798aec429ddcce`
- Button PR #47: `c9fefddaf0e925c9a20bdab10496e569e9652c95` (tree `51158f54771fabf31c258f7f6775dec1b2243613`)
- Accessibility foundation PR #48: `90d0c3e5ae3037aac6bed96c3044623efd6d3e30` (tree `60c574e4f433bdbcddc670b2cf546548909f9ea1`)

Run the fixture’s headless tests with the repository’s configured MoonBit
toolchain:

```sh
eval "$(python3 infra/linux-desktop/gpui-desktop.py env)"
moon test --package f4ah6o/gpui/examples/ubuntu_button/fixture --target native --deny-warn
```
