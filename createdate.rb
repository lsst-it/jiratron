#!/usr/bin/env ruby
# frozen_string_literal: true

require 'active_support'
require 'active_support/core_ext/date/calculations'
require 'date'
require 'jira-ruby'
require 'json'
require 'rest-client'
require 'yaml'

noop = false

foreman_hostname = 'foreman.cp.lsst.org'

jira_options = {
  username: ENV['JIRA_USER'],
  password: ENV['JIRA_PASS'],
  site: 'https://jira.lsstcorp.org',
  context_path: '',
  auth_type: :basic,
}

# https://stackoverflow.com/a/24509116
class Date
  def skip_to_thursday
    # given current weekday, how many days we need to add for it to become
    # thursday for example, for monday (weekday 1) it's 3 days
    offset = ->(x) { (4 - x) % 7 }
    self + offset[wday]
  end
end

# Generate the date of 2nd thursday of each month starting from the
# `start_date`.
class MaintDay
  include Enumerable

  def initialize(start_date = Date.today)
    @d = start_date
  end

  def each
    loop do
      @d = @d.beginning_of_month
      # 1st thursday of month
      @d = @d.skip_to_thursday
      # 2nd thursday of month
      @d = @d.next_week
      @d = @d.skip_to_thursday
      yield @d
      @d = @d.next_month
    end
  end
end

# Retrive a list of hosts from a foreman instance.
class ForemanHosts
  def initialize(hostname:)
    res = RestClient::Request.execute(
      method: :get,
      url: "https://#{hostname}/api/v2/hosts",
      user: ENV['FOREMAN_USER'],
      password: ENV['FOREMAN_PASS'],
      verify_ssl: false,
    )

    @results = JSON.parse(res.to_str)
  end

  def hostgroup_filter(regex)
    @results['results'].filter { |h| h['hostgroup_title'] =~ regex }
  end
end

def hostnames(hosts)
  hosts.map { |h| h['name'] }
end

def find_project(client, name)
  client.Project.find(name)
end

def find_issue_type(project, name)
  project.issueTypes.find { |it| it['name'] == name }
end

def find_component(project, name)
  project.components.find { |c| c.name == name }
end

def find_priority(client, name)
  client.Priority.all.find { |p| p.name == name }
end

hostgroup_patterns = %w[
  ^cp/comcam
  ^cp/auxtel
]

f = ForemanHosts.new(
  hostname: foreman_hostname,
)

groups = hostgroup_patterns.sort.each_with_object({}) do |hostgroup, res|
  res[hostgroup] = f.hostgroup_filter(%r{#{hostgroup}})
end

hosts_summary = hostgroup_patterns.sort.each_with_object({}) do |pattern, res|
  res[pattern] = hostnames(groups[pattern]).sort
end

mday = MaintDay.new(Date.today.next_month).to_enum

client = JIRA::Client.new(jira_options)
project = find_project(client, 'TST')
fields = client.Field.map_fields

d = mday.next
start_date = d.strftime('%Y-%m-%d')
year = d.strftime('%Y')
month = d.strftime('%B')

issue = client.Issue.build
issue.save({
             fields: {
               summary: "jch test - #{month}, #{year}",
               project: {
                 id: project.id,
               },
               issuetype: {
                 id: find_issue_type(project, 'Improvement')['id'],
               },
               assignee: {
                 name: 'jhoblitt',
               },
               # priority: {
               #  id: find_priority(client, 'SUMMIT-1').id,
               # },
               fields['Start_date'] => start_date,
               fields['End_date'] => start_date,
               components: [find_component(project, 'Something')],
               labels: ['it-calendar'],
               description: <<~MSG.chomp,
      Maintenance is planned on these hosts:

      {code}
      #{YAML.dump(hosts_summary)}
      {code}
               MSG
             },
           })

begin
  if noop
    pp issue
  else
    issue.fetch
    puts "#{issue.key} - #{issue.summary}"
  end
rescue JIRA::HTTPError => e
  puts e
end
