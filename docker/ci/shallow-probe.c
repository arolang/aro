// Does this libgit2 walk a shallow clone? (GitLab #897)
//
// Built and run while the CI image is built. The sequence is the one
// `ARORuntime/Git/GitService.swift` performs for `Retrieve the <log> from the
// <git>`: open the repository, push HEAD onto a revwalk, take commits off it.
//
// libgit2 1.1 — what Ubuntu jammy packages — has no shallow support. On a
// `--depth` clone it succeeds at every step and yields NOTHING: push_head
// returns 0, and the first `git_revwalk_next` returns ENOTFOUND because
// preparing the walk resolves a parent past the graft. The caller cannot tell
// that from a repository with no commits.
//
// Exits non-zero if the walk comes back empty, which fails the image build.

#include <git2.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: shallow-probe <repo>\n"); return 2; }
    git_libgit2_init();

    printf("libgit2 %s\n", LIBGIT2_VERSION);

    git_repository *repo = NULL;
    if (git_repository_open(&repo, argv[1]) != 0) {
        const git_error *e = git_error_last();
        fprintf(stderr, "cannot open %s: %s\n", argv[1], e ? e->message : "?");
        return 1;
    }
    printf("is_shallow=%d head_detached=%d\n",
           git_repository_is_shallow(repo), git_repository_head_detached(repo));

    git_revwalk *walk = NULL;
    if (git_revwalk_new(&walk, repo) != 0) { fprintf(stderr, "revwalk_new failed\n"); return 1; }
    git_revwalk_sorting(walk, GIT_SORT_TIME);
    if (git_revwalk_push_head(walk) != 0) {
        fprintf(stderr, "push_head failed\n");
        return 1;
    }

    git_oid oid;
    int n = 0, rc;
    while ((rc = git_revwalk_next(&oid, walk)) == 0) {
        git_commit *commit = NULL;
        if (git_commit_lookup(&commit, repo, &oid) != 0) break;
        git_commit_free(commit);
        n++;
    }
    printf("walked %d commit(s), next_exit=%d\n", n, rc);

    if (n == 0) {
        const git_error *e = git_error_last();
        fprintf(stderr,
                "FAIL: this libgit2 cannot walk a shallow clone (%s).\n"
                "      `Retrieve the <log> from the <git>` would report a\n"
                "      repository with no commits. See GitLab #897.\n",
                e && e->message ? e->message : "no error reported");
        return 1;
    }
    printf("shallow walk OK\n");
    return 0;
}
