module Origin
  module Git
    # Get the branch name from the GIT repo.
    #
    # @return [String] branch name
    def get_branch
      branch_str = `git status | head -n1`.chomp
      branch_str =~ /.*branch (.*)/
      branch = $1 ? $1 : 'origin/master'
      return branch
    end
    
    # In case of local code changes, make a temporary commit before sync'ing the repository to a remote host.
    # @see Git#reset_temp_commit
    def temp_commit
      # Warn on uncommitted changes
      `git diff-index --quiet HEAD`

      if $? != 0
        # Perform a temporary commit
        puts "Creating temporary commit to build"
        `git commit -a -m "Temporary commit to build"`
        if $? != 0
          puts "No-op."
        else
          @temp_commit = true
          puts "Done."
        end
      end
    end
    
    # Undo the temporary commit.
    # @see Git#temp_commit
    def reset_temp_commit
      if @temp_commit
        puts "Undoing temporary commit..."
        `git reset HEAD^`
        @temp_commit = false
        puts "Done."
      end
    end
    
    def clone_repos(branch="master", clean=false)
      ADDTL_SIBLING_REPOS.each do |repo_name|
        repo_dir = File.join(self.repo_parent_dir, repo_name)
        repo_git_url = SIBLING_REPOS_GIT_URL[repo_name]
        
        remove_dir(repo_dir) if (File.exist?(repo_dir) and clean)
        unless File.exist?(repo_dir)
          inside(self.repo_parent_dir) do
            run("git clone #{repo_git_url}") || exit(1)
            inside(repo_dir) do
              run("git checkout #{branch}") || exit(1)
            end
          end
        end
      end
    end
  end
end