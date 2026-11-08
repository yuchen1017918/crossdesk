# 上游 issue 草稿：请补 `LICENSE-MIT` / `LICENSE-APACHE` 正本

> 用途：直接粘到 `github.com/xiachufang/motif/issues`。
> 提交人：**用户侧**（agent 无 GitHub 凭据，不代发）。提交后把 issue 编号回填到本文件 §3 跟踪表。
> 语言：英文（上游 README/代码注释均为英文，用英文更可能被处理）。
> 立场：请求补正**元数据完备性**，不是质疑许可有效性 —— 措辞已按此收窄，请勿在提交前加码。

---

## 1. 标题（任选，推荐 A）

**A（推荐，点明诉求 + 理由）**
```
Add LICENSE-MIT / LICENSE-APACHE files (license is declared as "MIT OR Apache-2.0" but no license text is in the repo)
```

B（更短）
```
Missing LICENSE files for the declared MIT OR Apache-2.0 license
```

---

## 2. 正文（可直接粘贴）

```markdown
Hi, thanks for Motif — it's been a pleasure to work with.

### What I found

The project declares a dual license in two places, which is unambiguous:

- `Cargo.toml` → `[workspace.package] license = "MIT OR Apache-2.0"`
- `README.md` → `## License` → `MIT OR Apache-2.0.`

However, there is no license **text** anywhere in the repository for the project itself.
Walking the tree recursively, the only license files are for vendored third-party components:

- `crates/libghostty-vt/LICENSE` (MIT, © Uzair Aftab, Leah Amelia Chen)
- `crates/libghostty-vt-sys/LICENSE` (same)
- `apps/flutter/lib/motif/platform/doubao_asr/DOUVO_LICENSE.txt` (MIT, © rhinoc)

There is no root `LICENSE`, `LICENSE-MIT`, `LICENSE-APACHE`, `COPYING`, or `NOTICE`.
GitHub's own license detection also reports `license: null` for the repository.

### Why this matters downstream

I'd like to redistribute the `motifd` binary as part of a product. Under either branch of the
declared dual license, redistribution requires shipping the license text together with the
binary:

- MIT: "The above copyright notice and this permission notice shall be included in all copies
  or substantial portions of the Software."
- Apache-2.0: §4(a) requires recipients to receive a copy of the License.

With no license file and no copyright line in the repo, downstream redistributors have to
reconstruct both by hand — a standard MIT/Apache text is easy enough to supply, but the
**copyright holder line** has to be inferred from `[workspace.package] authors = ["Motif contributors"]`,
which is guesswork on our side rather than something you've stated.

### The ask

Could you add the canonical license files at the repository root?

- `LICENSE-MIT` — standard MIT text, with a copyright line, e.g.
  `Copyright (c) 2026 Motif contributors`
- `LICENSE-APACHE` — the standard Apache License 2.0 text
- optionally `LICENSE` — a short pointer file explaining the dual-license choice
  (the convention used by the Rust ecosystem, e.g. the `rust-lang` template)

If you'd prefer to declare a single license instead of dual, that's entirely your call — the
point is just that the text and the copyright holder line be present in the repo so that
redistributors don't have to guess.

### Additional minor items

- A `NOTICE` file isn't present. That's fine for MIT, but if you ever intend the Apache-2.0
  branch to be usable, Apache-2.0 §4(d) makes NOTICE handling relevant.
- `apps/flutter/ghostty` is a git submodule pointing at `ghostty-org/ghostty`. Worth a line in
  the README noting the submodule carries its own license, so redistributors know to include it.

Happy to send a PR with the files if you'd like — just say the word and tell me which copyright
line you want.

Thanks!
```

---

## 3. 跟踪表（提交后回填）

| 项 | 值 |
|---|---|
| issue URL | _待填_ |
| issue 编号 | _待填_ |
| 提交日期 | _待填_ |
| 提交人 | 用户侧 |
| 上游响应 | _待填_ |
| 状态 | **未提交**（草稿就绪） |

回填后，同步更新：

- `G-actions.md` → G3 的"验收：issue 有编号"
- `templates/README.md` §5 退出条件（上游合并后停用自构造版权行）
- `decision.md` §8 改选触发条件第 1 条（若上游一并补了 `LICENSE-APACHE` + `NOTICE`，重评 Apache 分支）

---

## 4. 提交注意事项

1. **先搜 issue 列表**，确认没人提过（重复 issue 会被直接关掉，反而降低被处理的概率）。
2. **不要带情绪、不要提"你们违法"之类的措辞** —— 上游确实明示了许可，缺的只是正本文件；把这一点说清楚，反而更容易被接受。
3. **给出可执行的替代方案**：正文已含"我可以提 PR，只要告诉我版权行怎么写"。这比自己 PR 一个猜出来的版权行更稳妥。
4. 若 14 天无响应：不再追（已经有了自备正本 + `SOURCE.md` 的完整替代路径，`decision.md` 判定不依赖上游响应）。追 issue 的边际收益低于追它带来的摩擦。
5. 上游若回复"我们用的是 X 许可"但与 manifest 不符：以**仓库内最新 manifest** 为准更新 `decision.md`，并记录该对话链接。

---

## 5. 如果上游先回复"直接 PR 吧"——PR 内容清单

| 文件 | 内容 | 注意 |
|---|---|---|
| `LICENSE-MIT` | 标准 MIT，版权行按上游指示填 | 不要自行决定版权行；等他们给 |
| `LICENSE-APACHE` | Apache-2.0 标准全文（含 `APPENDIX`） | 逐字拷贝，不要改标题层级 |
| `LICENSE` | 3–5 行指针：说明双许可、指向上面两个文件 | Rust 生态惯例 |
| `README.md` | `## License` 段补一句链接到 `LICENSE-MIT`/`LICENSE-APACHE` | 保持原段落不动，只加链接 |

PR 描述里附上本文 §2 的"为什么重要"段落即可，不必重写。
