defmodule CloudIServiceFilesystem do
  use Mix.Project

  def project do
    [app: :cloudi_service_filesystem,
     version: "1.5.0",
     language: :erlang,
     description: description,
     package: package,
     deps: deps]
  end

  defp deps do
    [{:cloudi_core, "~> 1.5.0"},
     {:cowlib, "~> 1.0.0"}]
  end

  defp description do
    "Erlang/Elixir Cloud Framework Filesystem Service"
  end

  defp package do
    [files: ~w(src doc test rebar.config README.markdown),
     contributors: ["Michael Truog"],
     licenses: ["BSD"],
     links: %{"Website" => "http://cloudi.org",
              "GitHub" => "https://github.com/CloudI/" <>
                          "cloudi_service_db_filesystem"}]
   end
end
